import hashlib
import json
from pathlib import Path
import tempfile
import tkinter
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


class TestPersistenceSetup(unittest.TestCase):
    def test_sources_and_script_idempotent_without_build(self):
        project = ET.parse(ROOT / 'G_FPGA.xpr').getroot()
        files = project.findall("./FileSets/FileSet[@Name='sources_1']/File")
        for name in ('Flash_Command_Engine', 'Calibration_Record_Encoder', 'Calibration_Store'):
            self.assertEqual(sum(f.get('Path', '').endswith('/' + name + '.v') for f in files), 1)
        t = tkinter.Tcl();t.setvar('root_path', ROOT.as_posix())
        t.eval('''
            set registered {};set generics {ENABLE_RUNTIME_CALIBRATION=0 ENABLE_FLASH_READONLY_PROBE=1 OTHER=7 ENABLE_FLASH_PERSISTENCE=0}
            set props {};set exists 0
            proc get_projects {args} {return project}
            proc current_project {} {return project}
            proc get_filesets {args} {return sources_1}
            proc get_property {key p} {global root_path generics;if {$key eq "DIRECTORY"} {return $root_path};return $generics}
            proc get_files {args} {global registered;set p [lindex $args end];if {$p in $registered} {return $p};return {}}
            proc add_files {args} {global registered;lappend registered [lindex $args end]}
            proc set_property {args} {global props generics;lappend props $args;if {[lindex $args 0] eq "generic"} {set generics [lindex $args 1]}}
            proc get_ips {args} {global exists;if {$exists} {return vio_flash_store};return {}}
            proc create_ip {args} {global exists;set exists 1}
            proc generate_target {args} {}
            proc launch_runs {args} {error "BUILD FORBIDDEN"}
            proc program_hw_devices {args} {error "PROGRAM FORBIDDEN"}
            proc program_hw_cfgmem {args} {error "ERASE/PROGRAM FORBIDDEN"}
        ''')
        for _ in range(2):
            t.call('source', str(ROOT / 'scripts/setup_flash_persistence.tcl'))
        self.assertEqual(int(t.eval('llength $registered')), 8)
        self.assertEqual(t.splitlist(t.eval('set generics')),
                         ('OTHER=7', 'ENABLE_RUNTIME_CALIBRATION=1', 'ENABLE_FLASH_PERSISTENCE=1', 'ENABLE_FLASH_READONLY_PROBE=0'))

    def test_mcs_generation_requires_audit_and_never_programs(self):
        for safe in (True, False):
            with tempfile.TemporaryDirectory() as directory:
                d = Path(directory);bit = d / 'my file.bit';bit.write_bytes(b'fake-bit-for-offline-test')
                target = d / 'boot.mcs'
                t = tkinter.Tcl()
                payload = ':02000000AA99BB\n'
                if not safe:
                    payload += ':02000004003EBC\n:0100000000FF\n'
                payload += ':00000001FF\n'
                t.setvar('mcs_text', payload)
                t.eval('''
                    set cfgmem_calls {}
                    proc write_cfgmem {args} {
                        global cfgmem_calls mcs_text;lappend cfgmem_calls $args
                        set output [lindex $args end];set s [open $output w];puts -nonewline $s $mcs_text;close $s
                    }
                    proc program_hw_cfgmem {args} {error "PROGRAM FORBIDDEN"}
                    proc open_hw_target {args} {error "HARDWARE FORBIDDEN"}
                ''')
                t.call('source', str(ROOT / 'scripts/create_boot_mcs.tcl'))
                if safe:
                    report_path = t.call('rc_create_boot_mcs', str(bit), str(target))
                    report = json.loads(Path(str(report_path)).read_text())
                    self.assertEqual(report['bit_sha256'], hashlib.sha256(bit.read_bytes()).hexdigest())
                    self.assertTrue(target.is_file())
                    args = t.splitlist(t.eval('lindex $cfgmem_calls 0'))
                    self.assertEqual(args[args.index('-size') + 1], '4')
                    self.assertEqual(args[args.index('-interface') + 1], 'SPIx1')
                    with self.assertRaises(tkinter.TclError):
                        t.call('rc_create_boot_mcs', str(bit), str(target))
                else:
                    with self.assertRaises(tkinter.TclError):
                        t.call('rc_create_boot_mcs', str(bit), str(target))
                    self.assertFalse(target.exists())
                    self.assertTrue(Path(str(target) + '.pending.mcs').exists())


if __name__ == '__main__':
    unittest.main()
