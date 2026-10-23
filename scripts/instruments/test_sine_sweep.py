import unittest
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
from analyze_sine_sweep import scale_uv, analyze


class TestSweepScale(unittest.TestCase):
    def test_round_saturate_and_unsigned(self):
        self.assertEqual(scale_uv(1,32768),1)
        self.assertEqual(scale_uv(0,0xffffffff),0)
        self.assertEqual(scale_uv(0xffffffff,0xffffffff),0xffffffff)
        self.assertEqual(scale_uv(100,65536),100)

    def test_no_negative_or_implicit_float(self):
        for raw,gain in [(-1,1),(1,-1),(1.0,1),(True,1),(1,0x100000000)]:
            with self.assertRaises(ValueError):scale_uv(raw,gain)

    def test_plan_integrity_and_reference_labels(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            settings={'hz':100250,'vpp':0.1,'offset_v':0}
            (root/'plan.json').write_text(json.dumps({'load':'HIGHZ','points':[settings],'samples_per_point':1}))
            (root/'job.json').write_text(json.dumps({'status':'completed','simulated':False}))
            d=root/'point_000_sample_00';d.mkdir()
            raw={'vpp_out':1800,'vrms_out':626,'amp_f1_out':781000,'max_index_out':200,'frequency_hz':100000}
            record={'status':'completed','simulated':False,'settings':settings,'point':0,'sample':0,'fpga':raw}
            (d/'result.json').write_text(json.dumps(record))
            inspected={'completed_packet_samples':1,'last_registers':dict(raw),
                       'diagnostic':{'signal_valid':True,'error_code':0},'candidate_bins':[200,0,0]}
            profile={'reference':'generator_HIGHZ_display_setting_only',
                     'fits':{k:{'gain_q16':g} for k,g in [('vpp',3623460),('rms',3701829),('fft',4194)]}}
            with patch('analyze_sine_sweep.inspect_capture',return_value=inspected):
                result=analyze(root,profile)
                self.assertTrue(result['frequency_validity_pass'])
                self.assertEqual(result['max_abs_frequency_error_hz'],250)
                self.assertFalse(result['runtime_vio_measurement'])
                self.assertFalse(result['absolute_input_calibrated'])
                with self.assertRaises(ValueError):analyze(root,profile,expected_controls=4)
                inspected['diagnostic']['controls']=4
                self.assertTrue(analyze(root,profile,expected_controls=4)['frequency_validity_pass'])
                inspected['diagnostic']['acquisition_fault']=True
                self.assertFalse(analyze(root,profile,expected_controls=4)['frequency_validity_pass'])
                inspected['diagnostic']['acquisition_fault']=False
                inspected['completed_packet_samples']=0
                with self.assertRaises(ValueError):analyze(root,profile)
                inspected['completed_packet_samples']=1
                inspected['last_registers']['vpp_out']=1900
                with self.assertRaises(ValueError):analyze(root,profile)
                inspected['last_registers']=dict(raw)
                inspected['diagnostic']['signal_valid']=False
                self.assertFalse(analyze(root,profile)['frequency_validity_pass'])
            (root/'job.json').write_text(json.dumps({'status':'failed','simulated':False}))
            with self.assertRaises(ValueError):analyze(root,profile)
            with patch('analyze_sine_sweep.inspect_capture',return_value={**inspected,'diagnostic':{'signal_valid':True,'error_code':0}}):
                failed=analyze(root,profile,include_failed_plan=True)
                self.assertTrue(failed['frequency_validity_pass'])
                self.assertFalse(failed['overall_transaction_pass'])
                self.assertEqual(failed['source_job_status'],'failed')


if __name__=='__main__':unittest.main()
