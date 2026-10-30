"""Offline project/Tcl registration guards; no Vivado or hardware."""
from pathlib import Path
import tkinter
import unittest
import xml.etree.ElementTree as ET


NAMES=('Display_Unsigned_Divider','Display_Frame_Calibrator','Display_Sine_ROM','Display_Fundamental_Aligner','Display_Wave_Renderer',
       'Display_Spectrum_Renderer','Display_mV_Formatter','Display_UART_Command','Display_HMI')


class TestDisplayPrepareRegistration(unittest.TestCase):
    def test_project_sources_registered_without_changing_top(self):
        root=Path(__file__).resolve().parents[2]
        project=ET.parse(root/'G_FPGA.xpr').getroot()
        files=project.findall("./FileSets/FileSet[@Name='sources_1']/File")
        for name in NAMES:
            matches=[f for f in files if f.get('Path','').endswith('/'+name+'.v')]
            self.assertEqual(len(matches),1,name)
            uses={a.get('Val') for a in matches[0].findall('./FileInfo/Attr') if a.get('Name')=='UsedIn'}
            self.assertTrue({'synthesis','implementation','simulation'}<=uses)
        self.assertFalse(any(f.get('Path','').endswith('/tb_display_prepare.sv') for f in files))

    def make_tcl(self):
        t=tkinter.Tcl();root=Path(__file__).resolve().parents[2]
        t.setvar('project_root',root.as_posix())
        t.eval('''
            set registered {};set writes {}
            proc get_projects {args} {return project}
            proc current_project {} {return project}
            proc get_property {args} {global project_root;return $project_root}
            proc get_files {args} {
                global registered;set p [lindex $args end]
                if {[lsearch -exact $registered $p]>=0} {return $p};return {}
            }
            proc add_files {args} {global registered;lappend registered [lindex $args end]}
            proc set_property {name value file} {global writes;lappend writes $name}
            proc get_ips {args} {error "IP ACCESS FORBIDDEN"}
            proc generate_target {args} {error "IP GENERATION FORBIDDEN"}
            proc launch_runs {args} {error "BUILD FORBIDDEN"}
            proc program_hw_devices {args} {error "PROGRAM FORBIDDEN"}
        ''')
        return t,root

    def test_script_idempotent_no_ip_or_top_mutation(self):
        t,root=self.make_tcl()
        for _ in range(2):t.call('source',str(root/'scripts/setup_display_prepare.tcl'))
        self.assertEqual(int(t.eval('llength $registered')),len(NAMES))
        self.assertEqual(int(t.eval('llength $writes')),len(NAMES)*3*2)
        for prop in t.splitlist(t.eval('set writes')):
            self.assertIn(prop,('USED_IN_SYNTHESIS','USED_IN_IMPLEMENTATION','USED_IN_SIMULATION'))

    def test_wrong_project_rejected_before_writes(self):
        t,root=self.make_tcl();t.setvar('project_root',str(root/'not_this_project'))
        with self.assertRaises(tkinter.TclError):t.call('source',str(root/'scripts/setup_display_prepare.tcl'))
        self.assertEqual(int(t.eval('llength $registered')),0)
        self.assertEqual(int(t.eval('llength $writes')),0)


if __name__=='__main__':unittest.main()
