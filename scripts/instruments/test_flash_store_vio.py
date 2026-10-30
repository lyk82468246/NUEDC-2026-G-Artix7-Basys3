import json
from pathlib import Path
import struct
import tempfile
import tkinter
import unittest
from calibration_record import Bank, Record

ROOT = Path(__file__).resolve().parents[2]
A = Bank(True, 3623460, 3701829, 4194)
B = Bank(True, 3600000, 3750000, 4200)
def packed(bank):
    return (int(bank.enabled) << 96) | (bank.vpp_gain << 64) | (bank.rms_gain << 32) | bank.fft_gain


class TestFlashStoreVio(unittest.TestCase):
    def mock(self):
        t = tkinter.Tcl();t.setvar('saved_bank', packed(A));t.setvar('active_bank', packed(B))
        t.eval('''
            set saved_valid 1;set saved_seq 0;set saved_epoch 1;set active_epoch 2
            set source 1;set error 0;set ack 0;set request 0;set command 0;set busy 0
            set fail_save 0;set hold_ack 0;set commits {};set milliseconds 0
            proc hx {n} {
                set s {};for {set k 24} {$k>=0} {incr k -1} {append s [string index 0123456789abcdef [expr {($n>>($k*4))&15}]]};return $s
            }
            proc flags {} {
                global busy ack source saved_valid saved_bank active_bank error
                return [expr {(0x40<<16)|0x400|2|($busy?0x2001:0)|($ack<<9)|($error<<5)|($source<<3)|($saved_valid<<2)|(($saved_bank!=$active_bank)<<11)}]
            }
            proc get_hw_vios {args} {if {[string match *u_vio_flash_store* [lindex $args end]]} {return fs};return rc}
            proc get_hw_probes {args} {
                if {[lindex $args end] eq "fs"} {set names {store_status store_jedec store_sequence store_saved_epoch store_saved_bank store_request store_command}} else {set names {epoch flags active_vpp active_rms active_fft request staged_vpp staged_rms staged_fft staged_valid}}
                set result {};foreach n $names {lappend result "[lindex $args end]/$n"};return $result
            }
            proc refresh_hw_vio {args} {}
            proc get_property {key p} {
                global request command saved_seq saved_epoch saved_bank active_epoch active_bank busy
                set n [file tail $p]
                if {$key eq "NAME"} {return $p}
                if {$key eq "WIDTH"} {return 1}
                if {$key eq "OUTPUT_VALUE"} {return [expr {$n eq "store_request"?$request:$command}]}
                switch $n {
                    store_status {return [hx [flags]]} store_jedec {return c22016}
                    store_sequence {return [hx $saved_seq]} store_saved_epoch {return [hx $saved_epoch]}
                    store_saved_bank {return [hx $saved_bank]} epoch {return [hx $active_epoch]}
                    flags {return [hx [expr {0x81|($busy?32:0)}]]}
                    active_vpp {return [hx [expr {($active_bank>>64)&0xffffffff}]]}
                    active_rms {return [hx [expr {($active_bank>>32)&0xffffffff}]]}
                    active_fft {return [hx [expr {$active_bank&0xffffffff}]]}
                    default {return 0}
                }
            }
            proc set_property {key value p} {
                global request command
                if {$key ne "OUTPUT_VALUE"} {return}
                if {[file tail $p] eq "store_request"} {set request $value} else {set command $value}
            }
            proc commit_hw_vio {p} {
                global commits request command ack saved_bank active_bank saved_valid saved_seq saved_epoch active_epoch source error fail_save busy hold_ack
                lappend commits $p
                if {[file tail $p] ne "store_request"} {return}
                if {$hold_ack} {set busy 1;return}
                if {$command==1} {
                    if {$fail_save} {set error 11} else {
                        set error 0
                        if {$saved_bank!=$active_bank} {incr saved_seq;set source [expr {$source==1?2:1}];set saved_bank $active_bank;set saved_epoch $active_epoch;set saved_valid 1}
                    }
                } elseif {$command==2} {set active_bank $saved_bank;incr active_epoch;set error 0}
                set ack $request
            }
        ''')
        t.call('source', str(ROOT / 'scripts/flash_store_vio.tcl'))
        return t

    def test_save_snapshot_and_wear_skip(self):
        t = self.mock()
        self.assertEqual(t.eval('dict get [rc_save] disposition'), 'SAVED_AND_VERIFIED')
        self.assertEqual(int(t.eval('dict get [rc_store_status] bank')), packed(B))
        self.assertEqual(t.eval('dict get [rc_save] disposition'), 'UNCHANGED')
        self.assertEqual(int(t.eval('set saved_seq')), 1)

    def test_busy_rejects_save_apply_and_reload_before_commit(self):
        for operation in ('rc_save', 'rc_apply 1 2 3', 'rc_reload'):
            t = self.mock();t.setvar('busy', 1)
            with self.assertRaises(tkinter.TclError):
                t.eval(operation)
            self.assertEqual(int(t.eval('llength $commits')), 0)

    def test_failed_readback_no_retry(self):
        t = self.mock();t.setvar('fail_save', 1)
        with self.assertRaises(tkinter.TclError):
            t.eval('rc_save')
        self.assertEqual(int(t.eval('llength $commits')), 2)  # cmd, then request
        self.assertEqual(int(t.eval('set saved_bank')), packed(A))

    def test_reload_and_crc_json_export(self):
        t = self.mock();t.eval('rc_reload')
        self.assertEqual(int(t.eval('set active_bank')), packed(A))
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'bank.json'
            t.call('rc_export', str(target), 'build"line\n2')
            document = json.loads(target.read_text())
            self.assertEqual(document['saved_vpp_gain'], A.vpp_gain)
            self.assertEqual(document['active_fft_gain'], A.fft_gain)
            self.assertEqual(document['build_id'], 'build"line\n2')
            self.assertEqual(document['record_crc_reconstructed'], struct.unpack_from('<I', Record(0, A, 1).encode()[0], 56)[0])
            with self.assertRaises(tkinter.TclError):
                t.call('rc_export', str(target))

    def test_timeout_unknown_not_retried(self):
        t = self.mock();t.setvar('hold_ack', 1)
        t.eval('''rename clock real_clock
            proc clock {args} {global milliseconds;if {[lindex $args 0] eq "milliseconds"} {incr milliseconds 6000;return $milliseconds};return [real_clock {*}$args]}
        ''')
        with self.assertRaisesRegex(tkinter.TclError, 'UNKNOWN'):
            t.eval('rc_save')
        self.assertEqual(int(t.eval('llength $commits')), 2)


if __name__ == '__main__':
    unittest.main()
