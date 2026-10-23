import cmath
import math
import unittest
from reference_model import (N, FS, Tone, waveform, fft, cases, analyse,
                             filtered_tones, adc_fixture, spectrum, components, window_q15)


class ReferenceTests(unittest.TestCase):
    def test_raw_fft_scale_matches_cordic_fractional_alignment(self):
        # Independent raw-code check; inverse conversion alone would conceal
        # an erroneous factor of two if both formulas shared that mistake.
        samples = waveform([Tone(100000,10)])
        mags, coherent_sum = spectrum(adc_fixture(samples))
        self.assertAlmostEqual(mags[200]/(320*coherent_sum/2),1,delta=.003)
        self.assertAlmostEqual(coherent_sum,sum(window_q15())/32768)

    def test_fft_against_direct_dft(self):
        values = [3,-2,7,4,1,0,-1,9]
        expected = [sum(x*cmath.exp(-2j*math.pi*k*i/8) for i,x in enumerate(values)) for k in range(8)]
        for a,b in zip(fft(values),expected):
            self.assertAlmostEqual(abs(a-b),0,places=10)

    def test_composites_frequency_and_peak_units(self):
        for name, mode, tones in cases():
            with self.subTest(name=name):
                r, _, _ = analyse(name,mode,tones)
                self.assertEqual(len(r['components']),len(tones))
                for measured, true in zip(r['components'],sorted(tones,key=lambda t:t.hz)):
                    self.assertLessEqual(abs(measured['hz']-true.hz),1000)
                    self.assertLessEqual(abs(measured['peak_mv']-true.peak_mv),5)

    def test_strongest_harmonic_is_not_fundamental(self):
        name,mode,tones=cases()[0]
        r,_,_=analyse(name,mode,tones)
        self.assertEqual(r['components'][0]['hz'],10500)
        self.assertGreater(r['components'][1]['peak_mv'],r['components'][0]['peak_mv'])

    def test_rms_is_not_vpp_over_sqrt8(self):
        tones=[Tone(10000,30),Tone(30000,20,.7),Tone(40000,10,1.2)]
        x=waveform(tones)
        rms=math.sqrt(sum(s*s for s in x)/N)
        self.assertAlmostEqual(rms,math.sqrt(700),places=8)
        self.assertGreater(abs(rms-(max(x)-min(x))/math.sqrt(8)),1)

    def test_phase_changes_vpp_but_not_full_period_rms(self):
        a=waveform([Tone(10000,30),Tone(30000,20),Tone(40000,10)])
        b=waveform([Tone(10000,30),Tone(30000,20,1.3),Tone(40000,10,.7)])
        self.assertGreater(abs((max(a)-min(a))-(max(b)-min(b))),1)
        self.assertAlmostEqual(sum(x*x for x in a),sum(x*x for x in b),places=5)

    def test_one_mhz_ideal_fir_rejects_interference(self):
        ub=[Tone(10500,20),Tone(31500,30),Tone(42000,10)]
        mixed=filtered_tones(ub+[Tone(1000000,100)])
        _,_,mags=analyse('C','B',mixed)
        peaks=components(mags)
        self.assertEqual(len(peaks),3)
        self.assertLess(mixed[-1].peak_mv,.1)

    def test_digital_filter_cannot_remove_aliased_four_mhz(self):
        # This expected limitation is a test, NOT a claimed C-mode pass.
        aliased=filtered_tones([Tone(4_000_000,100)])[0]
        self.assertGreater(aliased.peak_mv,90)
        self.assertEqual(abs(4_000_000-FS),96000)

    def test_adc_fixture_has_real_signed_width_and_scale(self):
        self.assertEqual(adc_fixture([-1,0,1]),[-32,0,32])
        self.assertEqual(adc_fixture([-2000,2000]),[-32768,32752])


if __name__ == '__main__':
    unittest.main()
