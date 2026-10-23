import unittest
from fit_amplitude_calibration import fit_pairs


class TestAmplitudeFit(unittest.TestCase):
    def test_exact_gain(self):
        r=fit_pairs([(100,5000),(200,10000),(300,15000)])
        self.assertEqual(r['gain_q16'],50*65536)
        self.assertEqual(r['max_fit_residual_uv'],0)
        self.assertEqual(r['affine_intercept_uv_diagnostic_only'],0)

    def test_invalid_reference_and_levels(self):
        for pairs in ([],[(1,1),(2,2)],[(1,1),(1,1),(2,2)],
                      [(0,1),(2,2),(3,3)],[(1,1),(2,2),(float('nan'),3)]):
            with self.assertRaises(ValueError):fit_pairs(pairs)

    def test_intercept_is_diagnostic_not_applied(self):
        r=fit_pairs([(11,10),(21,20),(31,30)])
        self.assertAlmostEqual(r['affine_intercept_uv_diagnostic_only'],-1)
        self.assertNotEqual(r['gain_q16'],65536)


if __name__=='__main__':unittest.main()
