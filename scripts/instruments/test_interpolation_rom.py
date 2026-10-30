import cmath
import math
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_interpolation_rom import coefficients, verilog


class TestInterpolationROM(unittest.TestCase):
    def test_registered_rom_matches_generator(self):
        root = Path(__file__).resolve().parents[2]
        self.assertEqual((root / 'sources/rtl/Display_Interpolation_ROM.v').read_text(encoding='utf-8'), verilog())

    def test_dc_integer_phase_and_signed_range(self):
        table = coefficients()
        self.assertEqual(len(table), 1024)
        self.assertEqual(table[:16], [0] * 7 + [16384] + [0] * 8)
        for phase in range(64):
            row = table[phase * 16:(phase + 1) * 16]
            self.assertEqual(sum(row), 16384)
            self.assertTrue(all(-32768 <= c <= 32767 for c in row))

    def test_complex_passband_preserves_harmonics(self):
        table = coefficients()
        for phase in range(64):
            for frequency in (0, 10000, 100000, 200000, 300000, 500000, 600000):
                omega = 2 * math.pi * frequency / 4096000
                actual = sum(table[phase * 16 + k] / 16384 * cmath.exp(1j * omega * (k - 7)) for k in range(16))
                ideal = cmath.exp(1j * omega * phase / 64)
                self.assertLess(abs(actual - ideal), 0.001)


if __name__ == '__main__':
    unittest.main()
