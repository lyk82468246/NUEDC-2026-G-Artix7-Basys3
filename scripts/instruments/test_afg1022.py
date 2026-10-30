import struct
import threading
import unittest
from unittest.mock import Mock

from afg1022 import AFG1022, is_afg_resource, sample_codes, validate_settings


class AFGTests(unittest.TestCase):
    def device(self):
        d = AFG1022.__new__(AFG1022)
        d._io_lock = threading.RLock()
        d.broken = False
        d.device = Mock()
        return d

    def test_resource_isolation(self):
        self.assertTrue(is_afg_resource('USB0::0x0699::0x0353::1931263::INSTR'))
        self.assertFalse(is_afg_resource('USB0::0x6656::0x0834::123::INSTR'))
        self.assertFalse(is_afg_resource('ASRL3::INSTR'))

    def test_envelope_accounts_for_open_circuit(self):
        for args in ({'hz': float('nan')}, {'vpp': True}, {'load': '50', 'vpp': 5, 'offset_v': .1}, {'hz': 30e6}):
            with self.subTest(args=args), self.assertRaises(ValueError):
                validate_settings(**args)
        validate_settings(load='50', vpp=5)

    def test_invalid_config_has_no_io(self):
        d = self.device()
        with self.assertRaises(ValueError):
            d.configure(vpp=99)
        self.assertEqual(d.device.mock_calls, [])

    def test_config_failure_sends_off_never_on(self):
        d = self.device()
        d.device.write.side_effect = IOError('disconnected')
        with self.assertRaises(IOError):
            d.configure()
        commands = [call.args[0] for call in d.device.write.call_args_list]
        self.assertIn('OUTP1 OFF', commands)
        self.assertIn('OUTP2 OFF', commands)
        self.assertFalse(any(' ON' in c for c in commands))

    def test_upload_packet_and_complete_readback(self):
        d = self.device()
        d.output_off = Mock()
        d._write = Mock()
        d._check_error = Mock()
        d.query = Mock(return_value='3')
        d.device.write_raw.side_effect = len
        d.device.query_binary_values.return_value = [0, 8192, 16383]
        result = d.upload_arb([-1, 0, 1])
        self.assertEqual(result['points'], 3)
        packet = d.device.write_raw.call_args.args[0]
        self.assertEqual(packet, b'DATA:DATA EMEMory,#16' + struct.pack('<3H', 0, 8192, 16383) + b'\n')
        d.device.query_binary_values.return_value = [0, 8191, 16383]
        with self.assertRaises(RuntimeError):
            d.upload_arb([-1, 0, 1])

    def test_samples_are_not_clipped(self):
        self.assertEqual(sample_codes([-1, 1]), [0, 16383])
        self.assertEqual(len(sample_codes([0] * 8192)), 8192)
        for samples in ([0], [0] * 8193, [0, float('inf')], [False, 1], [-1.1, 1]):
            with self.assertRaises(ValueError):
                sample_codes(samples)


if __name__ == '__main__':
    unittest.main()
