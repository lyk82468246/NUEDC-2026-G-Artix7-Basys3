import tempfile
import unittest
from pathlib import Path
from inspect_ila import inspect_capture


class InspectILATest(unittest.TestCase):
    def test_raw_candidates_do_not_become_qualified_measurements(self):
        headers='measurement_valid,vpp_out,vrms_out,amp_f1_out,max_index_out,diagnostic_bins,component_magnitudes,component_count,frame_id,calibration_epoch,snapshot_metadata'
        bins=193|(200<<12)|(207<<24)
        mags=10000|(1600000<<32)|(8000<<64)
        for raw in (False,True):
            with self.subTest(raw=raw),tempfile.TemporaryDirectory() as directory:
                path=Path(directory)/'capture.csv'
                fields=[1,1850,644,0,0,bins,mags,3,17,1,0x86 if raw else 6]
                path.write_text(headers+'\n'+','.join(['HEX']*11)+'\n'+','.join(format(x,'x') for x in fields)+'\n')
                if not raw:
                    with self.assertRaisesRegex(ValueError,'Invalid signal'):
                        inspect_capture(path)
                else:
                    result=inspect_capture(path)
                    self.assertEqual(result['candidate_snapshot']['bins'],[193,200,207])
                    self.assertEqual(result['candidate_snapshot']['magnitudes_raw'],[10000,1600000,8000])
                    self.assertFalse(result['candidate_snapshot']['qualified'])
                    self.assertEqual(result['component_snapshot']['schema'],3)
                    self.assertEqual(result['component_snapshot']['count'],0)
                    self.assertEqual(result['component_snapshot']['magnitudes_raw'],[0,0,0])

    def test_status_mapping_and_immediate_is_not_fresh(self):
        status = (1 << 28) | (4 << 25) | (2 << 20) | (1 << 18) | 0b11000
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'capture.csv'
            path.write_text('Sample in Buffer,measurement_valid,diagnostic_status[31:0],diagnostic_adc[11:0],diagnostic_bins[35:0]\n'
                            'Radix - UNSIGNED,HEX,HEX,HEX,HEX\n'
                            f'0,0,{status:x},800,{(376 << 12) | 200:x}\n', encoding='utf-8')
            result = inspect_capture(path)
        self.assertEqual(result['completed_packet_samples'], 0)
        self.assertEqual(result['diagnostic']['run_state'], 4)
        self.assertEqual(result['diagnostic']['error_code'], 1)
        self.assertEqual(result['diagnostic']['controls'], 2)
        self.assertTrue(result['diagnostic']['controller_release'])
        self.assertFalse(result['diagnostic']['capture_enable'])
        self.assertEqual(result['candidate_bins'], [200, 376, 0])
        self.assertEqual(result['adc_window'], {'min': 2048, 'max': 2048})
        self.assertEqual(result['diagnostic']['events_since_frame_start'], {
            'frame_complete': True, 'time_complete': True, 'fft_complete': False,
            'peak_complete': False, 'measurement_snapshot': False})


if __name__ == '__main__':
    unittest.main()
