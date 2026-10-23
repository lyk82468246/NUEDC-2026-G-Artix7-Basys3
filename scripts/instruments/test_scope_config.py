"""Offline scope settings/readback tests; never opens USB."""
import copy
import threading
import unittest
from hds242s import HDS242S, validate_scope_config

CONFIG = {'channel': 1, 'probe': '1X', 'coupling': 'DC',
          'scale': '100mV', 'timebase': '2.0us'}


class ScopeConfigTests(unittest.TestCase):
    def device(self):
        device = HDS242S.__new__(HDS242S)
        device._io_lock = threading.RLock()
        device.commands = []
        device.set = device.commands.append
        device.header = {'CHANNEL': [{'NAME': 'CH1', 'PROBE': '1X', 'COUPLING': 'DC',
                                      'SCALE': '100mV'}], 'TIMEBASE': {'SCALE': '2.0us'}}
        device.snapshot = lambda channels: {'header': copy.deepcopy(device.header)}
        return device

    def test_whitelist_rejects_injection_and_bool_channel(self):
        self.assertEqual(validate_scope_config(CONFIG), CONFIG)
        for key, value in [('channel', True), ('channel', 3), ('probe', '1X;:CHANnel ON'),
                           ('timebase', '1ms'), ('scale', '1V'), ('coupling', 'GND')]:
            config = dict(CONFIG, **{key: value})
            device = self.device()
            with self.assertRaises(ValueError):
                device.configure_scope(config)
            self.assertEqual(device.commands, [])

    def test_exact_commands_and_readback(self):
        device = self.device()
        result = device.configure_scope(CONFIG)
        self.assertEqual(result['requested'], CONFIG)
        self.assertEqual(device.commands, [':CH1:DISPlay ON', ':CH1:PROBe 1X',
            ':CH1:COUPling DC', ':CH1:SCALe 100mV', ':HORIzontal:SCALe 2.0us',
            ':ACQuire:MODe SAMPle', ':ACQuire:DEPMem 8K'])

    def test_readback_mismatch_is_not_success(self):
        device = self.device()
        device.header['CHANNEL'][0]['PROBE'] = '10X'
        with self.assertRaisesRegex(RuntimeError, 'readback mismatch'):
            device.configure_scope(CONFIG)


if __name__ == '__main__':
    unittest.main()
