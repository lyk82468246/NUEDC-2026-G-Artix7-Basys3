"""Offline selection/rollback Tcl mock; no Vivado or hardware access."""
from pathlib import Path
import unittest
try:
    import tkinter
except ImportError:
    tkinter=None


@unittest.skipIf(tkinter is None,'Tcl unavailable; selection script NOT validated here')
class TestFIREqualizationTcl(unittest.TestCase):
    def setUp(self):
        self.t=tkinter.Tcl()
        self.root=Path(__file__).resolve().parents[2]
        self.t.setvar('mock_root',self.root.as_posix())
        self.t.eval('''
            array set properties {
                CONFIG.Coefficient_Width 16 CONFIG.Coefficient_Fractional_Bits 15
                CONFIG.Coefficient_Sign Signed CONFIG.Quantization Quantize_Only
                CONFIG.BestPrecision false CONFIG.Coefficient_Sets 1
                CONFIG.Coefficient_Reload false CONFIG.Filter_Type Single_Rate
                CONFIG.Data_Width 16 CONFIG.Output_Width 16
                CONFIG.Data_Fractional_Bits 0
                CONFIG.Output_Rounding_Mode Truncate_LSBs
                CONFIG.Coefficient_Source Vector CONFIG.CoefficientVector ORIGINAL
            }
            set writes 0;set generates 0
            proc get_projects {args} {return project}
            proc current_project {} {return project}
            proc get_ips {args} {return ip}
            proc list_property {ip} {global properties;return [array names properties]}
            proc get_property {name object} {
                global mock_root properties
                if {$name eq "DIRECTORY"} {return $mock_root}
                return $properties($name)
            }
            proc set_property {option values ip} {
                global properties writes
                incr writes
                foreach {name value} $values {set properties($name) $value}
            }
            proc generate_target {target ip} {global generates;incr generates}
        ''')
        self.t.call('source',str(self.root/'scripts/setup_fir_equalization_experiment.tcl'))

    def test_explicit_experiment_and_baseline_rollback(self):
        self.assertEqual(int(self.t.eval('set writes')),0) # source must be inert
        result=self.t.eval('fir_eq_select experimental')
        self.assertEqual(int(self.t.call('dict','get',result,'sum_q15')),32672)
        result=self.t.eval('fir_eq_select baseline')
        self.assertEqual(int(self.t.call('dict','get',result,'sum_q15')),32768)
        self.assertEqual(int(self.t.eval('set generates')),2)

    def test_wrong_format_rejected_before_write(self):
        self.t.eval('set properties(CONFIG.Coefficient_Width) 18')
        with self.assertRaises(tkinter.TclError):self.t.eval('fir_eq_select experimental')
        self.assertEqual(int(self.t.eval('set writes')),0)
        with self.assertRaises(tkinter.TclError):self.t.eval('fir_eq_select unknown')

    def test_observed_derived_format_allows_rollback(self):
        self.t.eval('set properties(CONFIG.Coefficient_Fractional_Bits) 16')
        result=self.t.eval('fir_eq_select baseline')
        self.assertEqual(int(self.t.call('dict','get',result,'sum_q15')),32768)
        self.assertEqual(int(self.t.call('dict','get',result,'ip_fractional_bits')),16)

    def test_unknown_fraction_rejected_before_write(self):
        self.t.eval('set properties(CONFIG.Coefficient_Fractional_Bits) 14')
        with self.assertRaises(tkinter.TclError):self.t.eval('fir_eq_select experimental')
        self.assertEqual(int(self.t.eval('set writes')),0)


if __name__=='__main__':unittest.main()
