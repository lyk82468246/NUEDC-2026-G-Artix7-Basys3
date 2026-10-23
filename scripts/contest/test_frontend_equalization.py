"""Offline model checks. NumPy tests explicitly skip in stdlib-only envs."""
import cmath
import json
import math
from pathlib import Path
import unittest
try:
    import numpy as np
except ModuleNotFoundError:
    np=None
if np is not None:
    from frontend_equalization import (ROOT,FS,Tone,frontend,normalized_frontend,
        fit_frontend,design,response,frequency_metrics,run_case,normalize,load_base,dc_fixed,dc_response)


@unittest.skipIf(np is None,'NumPy unavailable: run with documented bundled Python; NOT a model pass')
class EqualizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        report=json.loads((ROOT/'docs/b_band_20261023_analysis.json').read_text(encoding='utf-8'))
        cls.fit=fit_frontend(report);cls.cap=cls.fit['effective_capacitance_pf']
        cls.amp=design(cls.cap,False);cls.phase=design(cls.cap,True)
        cls.tones=normalize([Tone(125000,1),Tone(375000,.5,.7),Tone(500000,.3,1.2)],250)

    def test_known_circuit_and_normalization(self):
        self.assertAlmostEqual(float(abs(frontend(0))),21.16)
        self.assertAlmostEqual(float(abs(normalized_frontend(100000,22))),1)
        self.assertAlmostEqual(float(abs(normalized_frontend(500000,22))),.946684,places=5)
        with self.assertRaises(ValueError):frontend(10,-1)

    def test_synthetic_cap_fit_and_provenance(self):
        rows=[]
        for hz in [250000,375000,500000]:
            scale=1.001*float(abs(normalized_frontend(hz,26)))
            rows.append({'frequency_validity_pass':True,'controls':4,
                'settings':{'hz':hz,'vpp':.1},
                'postprocessed_reference_mv':{'rms':100/math.sqrt(8)*scale,'fft':50*scale}})
        report={'absolute_input_calibrated':False,'records':rows}
        fitted=fit_frontend(report)
        self.assertAlmostEqual(fitted['effective_capacitance_pf'],26,places=2)
        self.assertAlmostEqual(fitted['nuisance_scalar'],1.001,places=6)
        self.assertFalse(fitted['phase_measured'])
        rows[0]['controls']=2
        with self.assertRaises(ValueError):fit_frontend(report)

    def test_quantized_structure_and_direct_dft(self):
        self.assertEqual(len(self.amp),95)
        self.assertTrue(np.array_equal(self.amp,self.amp[::-1]))
        self.assertFalse(np.array_equal(self.phase,self.phase[::-1]))
        self.assertLessEqual(max(abs(self.amp)),32767)
        hz=421234.5
        direct=sum(int(x)/32768*cmath.exp(-2j*math.pi*hz*n/FS) for n,x in enumerate(self.amp))
        self.assertLess(abs(response(self.amp,[hz])[0]-direct),1e-12)
        with self.assertRaises(ValueError):design(self.cap,taps=97)

    def test_response_and_stopband_on_independent_grid(self):
        freq=np.linspace(10000.7,499999.3,1703)
        for q in [self.amp,self.phase]:
            total=abs(normalized_frontend(freq,self.cap)*response(q,freq)*dc_response(freq))
            self.assertLess(float(max(abs(total-1))),.002)
            self.assertLess(frequency_metrics(q,self.cap)['digital_stopband_peak_db'],-60)

    def test_dc_fixed_point_order_and_saturation(self):
        result,clip=dc_fixed([16]*50000)
        self.assertFalse(clip)
        self.assertEqual(result[0],16)
        self.assertLessEqual(int(result[-1]),1)
        result,clip=dc_fixed([100000])
        self.assertTrue(clip);self.assertEqual(int(result[0]),32767)

    def test_model_composite_improves_without_scalar_postfit(self):
        original=run_case('old_sine',[Tone(500000,125)],load_base(),self.cap)
        self.assertGreater(abs(original['vpp_error_mv']),5)
        for q in [self.amp,self.phase]:
            r=run_case('new_composite',self.tones,q,self.cap)
            self.assertTrue(r['within_5mv_in_this_model'])
            self.assertFalse(r['adc_clipped'] or r['fir_clipped'] or r['dc_clipped'])

    def test_unknown_phase_not_identifiable_from_amplitude(self):
        for hz in [10000,125000,375000,500000]:
            s=2j*np.pi*hz*.5e-6
            self.assertAlmostEqual(abs((1-s)/(1+s)),1)
        r=run_case('unknown_phase',self.tones,self.phase,self.cap,allpass_tau=.5e-6)
        self.assertGreater(abs(r['vpp_error_mv']),5)
        self.assertFalse(r['within_5mv_in_this_model'])

    def test_one_mhz_vs_aliased_four_mhz_limit(self):
        r=run_case('one_mhz',self.tones,self.phase,self.cap,interference=Tone(1000000,100))
        self.assertTrue(r['within_5mv_in_this_model'])
        r=run_case('four_mhz',self.tones,self.phase,self.cap,interference=Tone(4000000,100))
        self.assertGreater(abs(r['vpp_error_mv']),5)
        self.assertFalse(r['within_5mv_in_this_model'])

    def test_effective_parameter_mismatch_is_explicit(self):
        r=run_case('nominal_22pf',self.tones,self.phase,22)
        self.assertTrue(r['within_5mv_in_this_model'])
        self.assertFalse(self.fit['phase_measured'])
        self.assertLess(self.fit['max_fit_residual_relative'],.002)


if __name__=='__main__':unittest.main()
