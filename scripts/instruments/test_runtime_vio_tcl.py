"""Offline Tcl API mock: no Vivado/JTAG connection or hardware writes."""
from pathlib import Path
import unittest
try:
    import tkinter
except ImportError:
    tkinter = None


@unittest.skipIf(tkinter is None, 'Tcl interpreter unavailable')
class TestRuntimeVioTcl(unittest.TestCase):
    def setUp(self):
        self.t = tkinter.Tcl()
        self.t.eval(r'''
            set names {staged_vpp staged_rms staged_fft staged_valid request ack epoch result_epoch count flags vpp_uv rms_uv peak_uv active_vpp active_rms active_fft}
            foreach n $names {set values($n) 0}
            set commits {}
            proc get_hw_vios {args} {return core}
            proc get_hw_probes {args} {
                global names
                set r {};foreach n $names {lappend r "g_runtime_calibration/$n"};return $r
            }
            proc get_property {property p} {
                global values
                if {$property eq "NAME"} {return $p}
                return $values([file tail $p])
            }
            proc set_property {property value p} {
                global values
                set values([file tail $p]) $value
            }
            proc refresh_hw_vio {args} {}
            proc commit_hw_vio {probes} {
                global values commits
                lappend commits $probes
                if {[lsearch -exact $probes g_runtime_calibration/request]>=0} {
                    set values(ack) $values(request)
                    scan $values(epoch) %x e;set values(epoch) [format %x [expr {$e+1}]]
                    foreach {a s} {active_vpp staged_vpp active_rms staged_rms active_fft staged_fft} {
                        set values($a) $values($s)
                    }
                    scan $values(flags) %x flags
                    set values(flags) [format %x [expr {($flags&254)|$values(staged_valid)}]]
                }
            }
        ''')
        self.t.call('source', str(Path(__file__).resolve().parents[1]/'runtime_calibration_vio.tcl'))

    def test_two_phase_commit_and_readback(self):
        self.t.eval('rc_apply 3623460 3701829 4194')
        self.assertEqual(int(self.t.eval('llength $commits')), 2)
        self.assertEqual(self.t.eval('set values(ack)'), '1')
        self.assertEqual(int(self.t.eval('rc::input core epoch')), 1)
        self.assertEqual(int(self.t.eval('rc::input core active_vpp')), 3623460)
        # Exact names: epoch must not accidentally match result_epoch.
        self.assertEqual(self.t.eval('rc::probe core epoch'), 'g_runtime_calibration/epoch')
        with self.assertRaises(tkinter.TclError):self.t.eval('rc_read')
        self.t.eval('set values(result_epoch) 1;set values(flags) 3;set values(count) 1;set values(vpp_uv) 186a0')
        self.assertEqual(int(self.t.eval('dict get [rc_read] vpp_uv')), 100000)

    def test_pending_invalid_and_overflow(self):
        with self.assertRaises(tkinter.TclError):self.t.eval('rc_apply 0 1 1')
        self.t.eval('set values(request) 1')
        with self.assertRaises(tkinter.TclError):self.t.eval('rc_apply 1 1 1')
        self.t.eval('set values(request) 0;set values(vpp_uv) ffffffff')
        self.assertEqual(int(self.t.eval('rc::input core vpp_uv')), 0xffffffff)
        for flags in ('7','13'):
            self.t.eval(f'set values(flags) {flags}')
            self.assertEqual(int(self.t.eval('dict get [rc_read] valid')), 0)
        self.t.eval('set values(flags) b')
        with self.assertRaises(tkinter.TclError):self.t.eval('rc_read')


if __name__ == '__main__':unittest.main()
