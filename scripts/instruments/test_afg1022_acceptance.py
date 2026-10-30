import json
import math
from pathlib import Path
import unittest

from afg1022_acceptance import prepare

VECTORS = Path(__file__).resolve().parents[2] / 'docs/acceptance_vectors'


class AcceptanceTests(unittest.TestCase):
    def plan(self, name):
        return json.loads((VECTORS / (name + '.json')).read_text(encoding='utf-8'))

    def peak(self, wave, hz):
        """Independent DFT of the 14-bit quantized voltage samples."""
        values = [(round((v + 1) * 16383 / 2) * 2 / 16383 - 1) * wave['vpp'] / 2
                  for v in wave['samples']]
        h, n = hz / wave['repeat_hz'], len(values)
        real = math.fsum(v * math.cos(math.tau * h * i / n) for i, v in enumerate(values))
        imag = math.fsum(v * math.sin(math.tau * h * i / n) for i, v in enumerate(values))
        return 2 * math.hypot(real, imag) / n

    def test_all_existing_vectors_keep_nominal_components(self):
        for path in sorted(VECTORS.glob('*.json')):
            with self.subTest(path=path.name):
                plan = self.plan(path.stem)
                wave = prepare(plan)
                self.assertEqual(wave['vpp'], plan['vpp'])
                for tone in plan['tones']:
                    self.assertAlmostEqual(self.peak(wave, tone['hz']), tone['vpp'] / 2, delta=2e-6)
                lower = .1 if path.stem.startswith('A_') else .05
                self.assertGreaterEqual(wave['signal_reference']['vpp_v'], lower)
                self.assertLessEqual(wave['signal_reference']['vpp_v'], .25)

    def test_c_keeps_signal_and_200mvpp_interference_at_same_scale(self):
        for hz in (1e6, 2e6, 4e6):
            for part in ('mixed', 'signal', 'interference'):
                with self.subTest(hz=hz, part=part):
                    wave = prepare(self.plan('B_HIGH'), interference_hz=hz, part=part)
                    self.assertAlmostEqual(wave['vpp'], .3)
                    self.assertAlmostEqual(wave['signal_reference']['vpp_v'], .068520527, places=8)
                    self.assertAlmostEqual(self.peak(wave, 125000),
                                           0 if part == 'interference' else .03, delta=2e-6)
                    self.assertAlmostEqual(self.peak(wave, hz),
                                           0 if part == 'signal' else .1, delta=2e-6)

    def test_bad_interference_is_rejected(self):
        for hz in (5e5, 1000001, 20e6, float('nan'), True):
            with self.subTest(hz=hz), self.assertRaises(ValueError):
                prepare(self.plan('B_HIGH'), interference_hz=hz)
        with self.assertRaises(ValueError):
            prepare(self.plan('A_THREE'), interference_hz=1e6)
        with self.assertRaises(ValueError):
            prepare(self.plan('B_LOW'), interference_hz=2e6)


if __name__ == '__main__':
    unittest.main()
