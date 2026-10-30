from pathlib import Path
import tkinter
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
NAMES = ('Flash_SPI_Byte', 'Flash_Read_Engine', 'Calibration_Record_Decoder',
         'Calibration_Record_Select', 'Calibration_Flash_Restore', 'Flash_Readonly_Probe')


class TestFlashReadOnlyTcl(unittest.TestCase):
    def test_timing_endpoint_checks_and_default_off(self):
        for enabled, missing in ((0, 0), (1, 0), (1, 1)):
            t = tkinter.Tcl();t.setvar('enabled', enabled);t.setvar('missing', missing)
            t.eval('''
                set maximums {};set minimums {}
                proc get_cells {args} {
                    global enabled missing;if {!$enabled} {return {}}
                    set f [lindex $args end]
                    if {[string match *rx_reg* $f]} {if {$missing} {return {}};return {rx0 rx1 rx2 rx3 rx4 rx5 rx6 rx7}}
                    if {[string match *mosi_reg* $f]} {return mosi_reg}
                    if {[string match *cs_n_reg* $f]} {return cs_n_reg}
                    return present
                }
                proc get_pins {args} {return {rx0/D rx1/D rx2/D rx3/D rx4/D rx5/D rx6/D rx7/D}}
                proc get_ports {p} {return $p}
                proc set_max_delay {args} {global maximums;lappend maximums $args}
                proc set_min_delay {args} {global minimums;lappend minimums $args}
                proc set_false_path {args} {error "FALSE PATH FORBIDDEN"}
            ''')
            if missing:
                with self.assertRaises(tkinter.TclError):
                    t.call('source', str(ROOT / 'sources/constraints/Flash_Readonly_Timing.xdc'))
            else:
                t.call('source', str(ROOT / 'sources/constraints/Flash_Readonly_Timing.xdc'))
                self.assertEqual(int(t.eval('llength $maximums')), 3 if enabled else 0)

    def test_project_registration(self):
        project = ET.parse(ROOT / 'G_FPGA.xpr').getroot()
        files = project.findall("./FileSets/FileSet[@Name='sources_1']/File")
        for name in NAMES:
            self.assertEqual(sum(f.get('Path', '').endswith('/' + name + '.v') for f in files), 1)
        self.assertNotIn('ENABLE_FLASH_READONLY_PROBE=1', (ROOT / 'G_FPGA.xpr').read_text(encoding='utf-8'))

    def test_setup_no_build_and_preserves_generics(self):
        t = tkinter.Tcl(); t.setvar('root_path', ROOT.as_posix())
        t.eval('''
            set registered {};set props {};set generics {ENABLE_RUNTIME_CALIBRATION=1 OTHER=7};set exists 0
            proc get_projects {args} {return project}
            proc current_project {} {return project}
            proc get_filesets {args} {return sources_1}
            proc get_property {key obj} {global root_path generics;if {$key eq "DIRECTORY"} {return $root_path};return $generics}
            proc get_files {args} {global registered;set p [lindex $args end];if {$p in $registered} {return $p};return {}}
            proc add_files {args} {global registered;lappend registered [lindex $args end]}
            proc set_property {args} {
                global props generics;lappend props $args
                if {[lindex $args 0] eq "generic"} {set generics [lindex $args 1]}
            }
            proc get_ips {args} {global exists;if {$exists} {return vio_flash_calibration};return {}}
            proc create_ip {args} {global exists;set exists 1}
            proc generate_target {args} {}
            proc launch_runs {args} {error "BUILD FORBIDDEN"}
            proc program_hw_devices {args} {error "PROGRAM FORBIDDEN"}
            proc program_hw_cfgmem {args} {error "FLASH PROGRAM FORBIDDEN"}
        ''')
        for _ in range(2):
            t.call('source', str(ROOT / 'scripts/setup_flash_readonly.tcl'))
        self.assertEqual(int(t.eval('llength $registered')), 7)
        self.assertEqual(t.splitlist(t.eval('set generics')),
                         ('ENABLE_RUNTIME_CALIBRATION=1', 'OTHER=7', 'ENABLE_FLASH_READONLY_PROBE=1'))

    def hardware_mock(self):
        t = tkinter.Tcl()
        t.eval('''
            set flags 402;set request 0;set commits 0
            proc get_hw_vios {args} {return core}
            proc refresh_hw_vio {args} {}
            proc get_hw_probes {args} {return {flash_status flash_jedec flash_sequence flash_saved_epoch flash_bank flash_request}}
            proc get_property {key p} {
                global flags request
                if {$key eq "NAME"} {return $p}
                if {$key eq "WIDTH"} {return 1}
                if {$key eq "OUTPUT_VALUE"} {return $request}
                switch $p {flash_status {return $flags} flash_jedec {return c22016} default {return 0}}
            }
            proc set_property {key v p} {global request;if {$key eq "OUTPUT_VALUE"} {set request $v}}
            proc commit_hw_vio {p} {global commits request flags;incr commits;set flags [format %x [expr {0x402 | ($request<<9)}]]}
        ''')
        t.call('source', str(ROOT / 'scripts/flash_readonly_vio.tcl'))
        return t

    def test_status_probe_and_no_write_commands(self):
        t = self.hardware_mock()
        self.assertEqual(t.eval('dict get [rc_store_status] stage'), 'READ_ONLY')
        self.assertEqual(int(t.eval('dict get [rc_store_status] jedec')), 0xC22016)
        self.assertEqual(int(t.eval('dict get [rc_store_probe] ack')), 1)
        t.setvar('flags', '20602')
        self.assertEqual(int(t.eval('dict get [rc_store_status] status_register')), 0x40)
        for command in ('rc_save', 'rc_reload'):
            with self.assertRaises(tkinter.TclError):
                t.eval(command)
        self.assertEqual(int(t.eval('set commits')), 1)

    def test_busy_or_pending_rejected(self):
        for flags, request in [('403', 0), ('402', 1)]:
            t = self.hardware_mock();t.setvar('flags', flags);t.setvar('request', request)
            with self.assertRaises(tkinter.TclError):
                t.eval('rc_store_probe')
            self.assertEqual(int(t.eval('set commits')), 0)


if __name__ == '__main__':
    unittest.main()
