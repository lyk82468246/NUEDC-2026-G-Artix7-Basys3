import struct
import unittest
import zlib
from calibration_record import (Bank, Record, InvalidRecord, SequenceConflict,
                                choose, decode_record, in_parameter_partition,
                                SLOT_A, SLOT_B)
from calibration_nor_model import NorModel, PowerCut, recover, save_applied


A = Bank(True, 3623460, 3701829, 4194)
B = Bank(True, 3600000, 3750000, 4200)
C = Bank(False, 3500000, 3800000, 4300)


def ready(image=None):
    nor = NorModel(image)
    nor.profile_confirmed = True  # fictional model profile ONLY
    return nor


class TestCalibrationRecord(unittest.TestCase):
    def test_crc_and_layout(self):
        self.assertEqual(zlib.crc32(b'123456789'), 0xCBF43926)
        record = Record(0xFFFFFFFF, A, 7)
        body, commit = record.encode()
        self.assertEqual((len(body), len(commit)), (64, 16))
        self.assertEqual(body[:8], b'GCAL\x01\x00\x40\x00')
        self.assertEqual(body[20:24], struct.pack('<I', A.vpp_gain))
        self.assertEqual(decode_record(body, commit), record)

    def test_every_body_or_commit_bit_corruption_rejected(self):
        body, commit = Record(2, A, 9).encode()
        for segment in (0, 1):
            for bit in range(len((body, commit)[segment]) * 8):
                parts = [bytearray(body), bytearray(commit)]
                parts[segment][bit // 8] ^= 1 << (bit % 8)
                with self.assertRaises(InvalidRecord):
                    decode_record(*parts)

    def test_invalid_banks(self):
        for bank in (Bank(True, 0, 1, 1), Bank(True, 1, -1, 1),
                     Bank(True, 1, 1, 1 << 32), Bank(1, 1, 1, 1)):
            with self.assertRaises(InvalidRecord):
                Record(0, bank, 0).encode()

    def test_sequence_wrap_and_conflict(self):
        old, new = Record(0xFFFFFFFF, A, 0), Record(0, B, 1)
        self.assertEqual(choose(old, new), 'B')
        self.assertEqual(choose(new, old), 'A')
        self.assertEqual(choose(new, new), 'A')
        with self.assertRaises(SequenceConflict):
            choose(new, Record(0, A, 1))
        with self.assertRaises(SequenceConflict):
            choose(new, Record(0x80000000, A, 0))
        self.assertIsNone(choose(None, None))

    def test_blank_alternation_and_no_wear(self):
        nor = ready()
        self.assertEqual(recover(nor), (None, None))
        self.assertEqual(save_applied(nor, A, 1)[0], 'SAVED')
        self.assertEqual(recover(nor)[0], 'A')
        before = nor.steps
        self.assertEqual(save_applied(nor, A, 50)[0], 'UNCHANGED')
        self.assertEqual(nor.steps, before)
        save_applied(nor, B, 2)
        self.assertEqual(recover(nor)[0], 'B')
        save_applied(nor, C, 3)
        self.assertEqual(recover(nor), ('A', Record(2, C, 3)))

    def test_power_cut_every_persistent_step(self):
        # First save, initial A->B, and overwriting stale A while B is current.
        nor = ready()
        scenarios = [(bytes(nor.memory), None, A, 1)]
        save_applied(nor, A, 1)
        scenarios.append((bytes(nor.memory), Record(0, A, 1), B, 2))
        save_applied(nor, B, 2)
        scenarios.append((bytes(nor.memory), Record(1, B, 2), C, 3))
        for image, previous, bank, epoch in scenarios:
            complete = ready(image)
            new = save_applied(complete, bank, epoch)[1]
            for cut in range(1, complete.steps + 1):
                flash = ready(image)
                flash.cut_after = cut
                with self.assertRaises(PowerCut):
                    save_applied(flash, bank, epoch)
                flash.power_cycle()
                self.assertIn(recover(flash)[1], (previous, new), (cut, previous))

    def test_unknown_protected_busy_and_wren(self):
        with self.assertRaises(RuntimeError):
            save_applied(NorModel(), A, 0)
        nor = ready()
        with self.assertRaises(RuntimeError):
            nor.program(SLOT_A, b'\x00')
        nor.protected = True
        with self.assertRaises(RuntimeError):
            nor.write_enable()
        nor.protected = False
        nor.write_enable(); nor.program(SLOT_A, b'\x00')
        with self.assertRaises(RuntimeError):
            nor.read(SLOT_A, 1)
        nor.poll_ready()
        nor.write_enable()
        with self.assertRaises(ValueError):
            nor.program(SLOT_A, b'\xff')

    def test_page_and_partition_guards(self):
        self.assertTrue(in_parameter_partition(SLOT_A, 0x20000))
        for address, count in ((SLOT_A - 1, 1), (0, 1), (SLOT_B + 65536, 1),
                               (SLOT_B, 65537), (SLOT_A, 0), (0xFFFFFFFF, 2)):
            self.assertFalse(in_parameter_partition(address, count))
        nor = ready(); nor.write_enable()
        with self.assertRaises(ValueError):
            nor.program(SLOT_A + 255, b'\x00\x00')
        with self.assertRaises(ValueError):
            nor.erase(0)
        self.assertEqual(nor.memory[:64], b'\xff' * 64)

    def test_readback_failure_does_not_commit(self):
        class BadReadback(NorModel):
            def read(self, address, count):
                result = super().read(address, count)
                if address == SLOT_B and count == 64 and self.steps > self.erase_size // 256 + 64:
                    return bytes([result[0] ^ 1]) + result[1:]
                return result
        nor = ready(); save_applied(nor, A, 1)
        broken = BadReadback(nor.memory); broken.profile_confirmed = True
        with self.assertRaises(InvalidRecord):
            save_applied(broken, B, 2)
        # Inspect the underlying storage independently of the injected read fault.
        self.assertEqual(recover(ready(broken.memory))[1], Record(0, A, 1))


if __name__ == '__main__':
    unittest.main()
