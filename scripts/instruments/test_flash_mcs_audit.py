import unittest
from audit_flash_mcs import audit


def line(kind, address=0, payload=b''):
    raw = bytes([len(payload), address >> 8, address & 255, kind]) + payload
    return ':' + (raw + bytes([-sum(raw) & 255])).hex()


class TestMCSAudit(unittest.TestCase):
    def test_boot_and_partition_bound(self):
        text = '\n'.join([line(0, payload=b'\xaa\x99'), line(4, payload=b'\x00\x3d'),
                          line(0, 0xFFFF, b'\x00'), line(1)])
        self.assertEqual(audit(text)['erase_end_exclusive'], 0x3E0000)

    def test_parameter_payload_rejected(self):
        text = '\n'.join([line(0, payload=b'\x00'), line(4, payload=b'\x00\x3e'),
                          line(0, payload=b'\x00'), line(1)])
        with self.assertRaises(ValueError):
            audit(text)

    def test_checksum_missing_eof_overlap_and_after_eof(self):
        good = line(0, payload=b'\xaa')
        for text in (good, good[:-2] + '00\n' + line(1), good + '\n' + good + '\n' + line(1),
                     good + '\n' + line(1) + '\n' + good):
            with self.assertRaises(ValueError):
                audit(text)

    def test_wrap_and_unknown_type_and_nonzero_start(self):
        for text in ('\n'.join([line(0, 65535, b'\x00\x00'), line(1)]),
                     '\n'.join([line(5, payload=bytes(4)), line(1)]),
                     '\n'.join([line(0, 1, b'\x00'), line(1)])):
            with self.assertRaises(ValueError):
                audit(text)


if __name__ == '__main__':
    unittest.main()
