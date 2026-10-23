"""Synthetic CSV and Tcl-contract tests: no USB/JTAG or Vivado project writes."""
import csv
from pathlib import Path
import tempfile
import unittest
import tkinter
from inspect_ila import inspect_capture
from hds242s import parse_ila_csv


class TestDebugSchema(unittest.TestCase):
    def write_csv(self,path,**changes):
        values=dict(debug_measurement_valid=0,debug_vpp=0x1ffff,debug_rms=0xffff,
            debug_fundamental=0x80000001,debug_fundamental_bin=100,
            debug_component_bins=(400<<24)|(300<<12)|100,
            debug_component_magnitudes=(0xffffffff<<64)|(0x80000002<<32)|0x80000001,
            debug_component_count=3,debug_frame_id=0xffffffff,debug_calibration_epoch=7,
            debug_metadata=15)
        values.update(changes)
        with path.open('w',newline='') as stream:
            writer=csv.writer(stream)
            writer.writerow(['Sample in Buffer']+['top/'+k for k in values])
            writer.writerow(['Radix - UNSIGNED']+['HEX']*len(values))
            writer.writerow(['0']+['0']*len(values)) # old packet before event
            values['debug_measurement_valid']=1
            writer.writerow(['1']+[format(v,'x') for v in values.values()])
            values['debug_measurement_valid']=0
            writer.writerow(['2']+[format(v,'x') for v in values.values()])

    def test_full_unsigned_and_atomic_event(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'new.csv';self.write_csv(p)
            packet=parse_ila_csv(p)
            self.assertEqual(packet['vpp_out'],0x1ffff)
            self.assertEqual(packet['amp_f1_out'],0x80000001)
            inspection=inspect_capture(p);s=inspection['component_snapshot']
            self.assertEqual(s['bins'],[100,300,400])
            self.assertEqual(s['magnitudes_raw'],[0x80000001,0x80000002,0xffffffff])
            self.assertEqual(s['frame_id'],0xffffffff)
            self.assertEqual(s['calibration_epoch'],7)

    def test_stale_slot_or_mismatched_fundamental_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'bad.csv';self.write_csv(p,debug_component_count=1)
            with self.assertRaises(ValueError):inspect_capture(p)
            self.write_csv(p,debug_fundamental_bin=101)
            with self.assertRaises(ValueError):inspect_capture(p)
            self.write_csv(p,debug_metadata=14)
            with self.assertRaises(ValueError):inspect_capture(p)

    def test_packet_changes_after_event_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'bad.csv';self.write_csv(p)
            with p.open(newline='') as stream:rows=list(csv.reader(stream))
            rows[-1][1+list(self._keys()).index('debug_frame_id')]='2'
            with p.open('w',newline='') as stream:csv.writer(stream).writerows(rows)
            with self.assertRaises(ValueError):inspect_capture(p)

    def _keys(self):
        return ('debug_measurement_valid','debug_vpp','debug_rms','debug_fundamental',
                'debug_fundamental_bin','debug_component_bins','debug_component_magnitudes',
                'debug_component_count','debug_frame_id','debug_calibration_epoch','debug_metadata')

    def test_ila_tcl_contract_inert_and_widths(self):
        t=tkinter.Tcl();t.eval('set writes 0;proc set_property {args} {global writes config;incr writes;set config [lindex $args 1]}')
        root=Path(__file__).resolve().parents[2]
        t.call('source',str(root/'scripts/measurement_debug_ila_config.tcl'))
        self.assertEqual(int(t.eval('set writes')),0)
        t.eval('configure_measurement_debug_ila ip')
        self.assertEqual(int(t.eval('dict get $config CONFIG.C_NUM_OF_PROBES')),15)
        for index,width in enumerate((1,17,16,32,12,5,32,12,36,32,96,2,32,32,8)):
            self.assertEqual(int(t.eval(f'dict get $config CONFIG.C_PROBE{index}_WIDTH')),width)

    def test_gui_setup_only_registers_snapshot_and_generates_ila(self):
        t=tkinter.Tcl();root=Path(__file__).resolve().parents[2]
        t.setvar('root',root.as_posix())
        t.eval('''
            set registered 0;set generated {};set ips {};set files {}
            proc get_projects {args} {return project}
            proc current_project {} {return project}
            proc get_property {args} {global root;return $root}
            proc get_files {args} {global registered; if {!$registered} {return {}};return file}
            proc add_files {args} {global registered files;set registered 1;lappend files [lindex $args end]}
            proc set_property {args} {}
            proc get_ips {args} {global ips;lappend ips [lindex $args end];return ila_system}
            proc generate_target {target ip} {global generated;lappend generated $ip}
            proc launch_runs {args} {error "BUILD FORBIDDEN"}
            proc program_hw_devices {args} {error "PROGRAM FORBIDDEN"}
        ''')
        t.call('source',str(root/'scripts/setup_measurement_debug.tcl'))
        self.assertEqual(t.eval('set generated'),'ila_system')
        self.assertEqual(t.eval('set ips'),'ila_system')
        self.assertTrue(t.eval('lindex $files 0').endswith('/Measurement_Debug_Snapshot.v'))


if __name__=='__main__':unittest.main()
