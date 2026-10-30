import math
import unittest

from afg_contest_waveform import build, preset
from afg1022 import sample_codes


class ContestWaveformTests(unittest.TestCase):
    def test_all_modes_and_c_interference_frequencies(self):
        for mode in ('A','B','C'):
            for hz in ((1000,2000,3000,3500,4000) if mode=='C' else (1000,)):
                with self.subTest(mode=mode,hz=hz):
                    p=preset(mode); p['interference_khz']=hz
                    d=build(p)
                    self.assertFalse(any('超出题目' in w for w in d['warnings']))
                    self.assertLessEqual(d['table_sample_rate_hz'],125e6)
                    codes=sample_codes(d['samples']); n=len(codes)
                    tones=d['tones']+([d['interference']] if mode=='C' else [])
                    for tone in tones:
                        k=round(tone['hz']/d['repeat_hz'])
                        volts=[(c/16383*2-1)*d['config']['vpp']/2 for c in codes]
                        sine=2/n*math.fsum(v*math.sin(math.tau*k*i/n) for i,v in enumerate(volts))
                        cosine=2/n*math.fsum(v*math.cos(math.tau*k*i/n) for i,v in enumerate(volts))
                        self.assertAlmostEqual(math.hypot(sine,cosine),tone['peak_v'],delta=2e-6)

    def test_c_parts_preserve_mapping(self):
        p=preset('C'); outputs=[]
        for part in ('混合信号','仅被测信号','仅干扰'):
            p['part']=part; outputs.append(build(p))
        for d in outputs:self.assertEqual(d['config'],outputs[0]['config'])
        for mixed,signal,interference in zip(*(d['samples'] for d in outputs)):
            self.assertAlmostEqual(mixed,signal+interference,places=12)

    def test_weak_baseline_reference(self):
        d=build(preset('B'))
        self.assertAlmostEqual(d['clean_vpp_mv'],87.754619,places=4)
        self.assertAlmostEqual(d['clean_rms_mv'],22.912878,places=4)

    def test_incompatible_common_period_rejected(self):
        p=preset('C'); p['f0_khz']=124.75
        with self.assertRaisesRegex(ValueError,'共同周期'):build(p)

    def test_two_components_and_limits(self):
        p=preset('A'); p['tones']=p['tones'][:2]
        self.assertEqual(len(build(p)['tones']),2)
        p['f0_khz']=100
        with self.assertRaises(ValueError):build(p)
        p=preset('C'); p['interference_khz']=999
        with self.assertRaises(ValueError):build(p)
        p=preset('B'); p['tones'][1]['order']=1
        with self.assertRaises(ValueError):build(p)

    def test_nonstandard_amplitude_warns(self):
        p=preset('C'); p['interference_vpp_mv']=100
        self.assertTrue(any('不是题目' in w for w in build(p)['warnings']))


if __name__=='__main__':unittest.main()
