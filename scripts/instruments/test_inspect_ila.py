import tempfile
import unittest
from pathlib import Path
from inspect_ila import inspect_capture


class InspectILATest(unittest.TestCase):
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
