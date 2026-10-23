"""Fit provisional sine calibration from COMPLETED, non-simulated plan records.

Reference is generator display setting, NOT independently measured input volts.
No hardware writes; produces report JSON and a Tcl coefficient dict. Through-zero
fit only; unconstrained intercept is reported as a diagnostic, never subtracted
from arbitrary waveforms. Off/noise data must not be used as calibration tones.
"""
import argparse
import json
import math
from pathlib import Path
from inspect_ila import inspect_capture


def fit_pairs(pairs):
    if len(pairs) < 3 or len({y for x, y in pairs}) < 3:
        raise ValueError('Need at least three distinct positive reference levels')
    if any(not math.isfinite(float(v)) or v <= 0 for p in pairs for v in p):
        raise ValueError('Positive finite raw/reference values required')
    sx = sum(x for x, _ in pairs)
    sy = sum(y for _, y in pairs)
    sxx = sum(x*x for x, _ in pairs)
    sxy = sum(x*y for x, y in pairs)
    slope = sxy/sxx
    gain = math.floor(slope*65536 + 0.5)
    if not 0 < gain <= 0xffffffff:
        raise ValueError('Gain outside Q16.16 range')
    den = len(pairs)*sxx-sx*sx
    affine_slope = (len(pairs)*sxy-sx*sy)/den
    errors = [x*gain/65536-y for x, y in pairs]
    return {'gain_q16': gain, 'gain_uv_per_raw': slope,
            'affine_intercept_uv_diagnostic_only': (sy-affine_slope*sx)/len(pairs),
            'max_fit_residual_uv': max(abs(e) for e in errors),
            'rms_fit_residual_uv': math.sqrt(sum(e*e for e in errors)/len(errors))}


def analyze(paths):
    rows = []
    for path in paths:
        r = json.loads(path.read_text(encoding='utf-8'))
        if r.get('simulated') is not False or r.get('status') != 'completed':
            raise ValueError(f'Not completed hardware data: {path}')
        settings, f = r['settings'], r['fpga']
        plan = json.loads((path.parent.parent/'plan.json').read_text(encoding='utf-8'))
        if plan.get('load') != 'HIGHZ':
            raise ValueError('Mixed or unknown generator load reference')
        # Scope-only/simulated/stale results cannot silently enter a fit.
        i = inspect_capture(path.parent/'ila.csv')
        if i['completed_packet_samples'] != 1 or not i['diagnostic']['signal_valid']:
            raise ValueError(f'No fresh valid signal: {path}')
        if any(i['last_registers'][k] != f[k] for k in ('vpp_out','vrms_out','amp_f1_out','max_index_out')):
            raise ValueError(f'Record does not match captured registers: {path}')
        if settings['offset_v'] != 0 or abs(f['frequency_hz']-settings['hz']) > 500:
            raise ValueError(f'Tone mismatch: {path}')
        if settings['hz'] != 100000 or not 0 < settings['vpp'] <= 0.1:
            raise ValueError('This provisional profile is limited to 100kHz <=100mVpp')
        if sum(b != 0 for b in i['candidate_bins']) != 1:
            raise ValueError(f'Not a single candidate: {path}')
        if any(f[k] <= 0 for k in ('vpp_out','vrms_out','amp_f1_out')):
            raise ValueError(f'Zero raw tone: {path}')
        uv = settings['vpp']*1e6
        rows.append({'source': str(path.resolve()), 'generator_setting_vpp_uv': uv,
                     'reference_rms_uv': uv/(2*math.sqrt(2)),
                     'reference_peak_uv': uv/2, 'raw': f})
    if not rows:
        raise ValueError('No records')
    mapping = {'vpp': ('vpp_out','generator_setting_vpp_uv'),
               'rms': ('vrms_out','reference_rms_uv'),
               'fft': ('amp_f1_out','reference_peak_uv')}
    fits = {name: fit_pairs([(r['raw'][x],r[y]) for r in rows])
            for name, (x, y) in mapping.items()}
    return {'schema': 1, 'reference': 'generator_HIGHZ_display_setting_only',
            'absolute_input_calibrated': False, 'frequency_hz': 100000,
            'units': 'reference microvolts; gain=unsigned Q16.16 microvolts/raw',
            'notes': ['50ohm filter input can halve HIGHZ setting; no automatic correction',
                      'RMS reference derives from sine formula, not independent measurement',
                      'FFT reference is sine peak, not Vpp',
                      'Fit residuals are in-sample consistency, NOT accuracy certification',
                      'Historical rail flag is sticky; no full-frame clipping certification'],
            'fits': fits, 'records': rows}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('plans', nargs='+', type=Path, help='Plan job directories; only completed point records are used')
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args()
    paths = sorted({path for plan in a.plans for path in plan.glob('point*/result.json')})
    result = analyze(paths)
    a.output.mkdir(parents=True, exist_ok=False)
    (a.output/'calibration.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    # This file defines data ONLY. Loading it does not touch hardware.
    gains = result['fits']
    (a.output/'coefficients.tcl').write_text(
        '# PROVISIONAL generator-setting reference, not actual input mV.\n'
        'set rc_coefficients [dict create '+
        ' '.join(f'{k} {gains[k]["gain_q16"]}' for k in ('vpp','rms','fft'))+']\n',encoding='utf-8')
    print(json.dumps({'reference':result['reference'],'fits':gains},indent=2))


if __name__ == '__main__':
    main()
