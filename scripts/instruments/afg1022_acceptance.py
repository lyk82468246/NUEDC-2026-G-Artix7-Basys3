"""Prepare acceptance ARB samples offline; never open or control an instrument."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from utg932_waveform import synthesize_multitone


def reference(tones, repeat_hz):
    """Dense ideal-period extrema and analytical AC RMS, in volts."""
    count = 262144
    harmonics = [round(tone['hz'] / repeat_hz) for tone in tones]
    values = [math.fsum(tone['vpp'] / 2 * math.sin(
        math.tau * harmonic * i / count + math.radians(tone['phase_deg']))
        for tone, harmonic in zip(tones, harmonics)) for i in range(count)]
    return dict(vpp_v=max(values) - min(values),
                rms_v=math.sqrt(math.fsum(t['vpp'] ** 2 for t in tones) / 8),
                components=[dict(hz=t['hz'], peak_v=t['vpp'] / 2,
                                 phase_deg=t['phase_deg']) for t in tones])


def prepare(plan, *, interference_hz=None, interference_phase_deg=0, part='mixed'):
    """Preserve the A/B tone settings; add exactly 200 mVpp for C.

    For C the interference must repeat within the existing A/B period. All
    three parts use the SAME full-scale setting, allowing independent checks.
    """
    if part not in ('mixed', 'signal', 'interference'):
        raise ValueError('Unknown waveform part')
    base = synthesize_multitone(plan)
    repeat, scale = base['repeat_hz'], base['vpp']
    tones = base['tones']
    signal_reference = reference(tones, repeat)
    values = base['samples']
    interference = None
    if interference_hz is None:
        if part != 'mixed':
            raise ValueError('--part requires --interference-hz')
    else:
        if isinstance(interference_hz, bool) or isinstance(interference_phase_deg, bool):
            raise ValueError('Interference settings must be finite numbers')
        hz, phase = float(interference_hz), float(interference_phase_deg)
        if not math.isfinite(hz) or not 1e6 <= hz <= 10e6 or not math.isfinite(phase):
            raise ValueError('Preparation range: interference 1..10 MHz, finite phase')
        harmonic = round(hz / repeat)
        if not math.isclose(hz / repeat, harmonic, rel_tol=0, abs_tol=1e-8):
            raise ValueError('Interference must be an integer multiple of repeat_hz; choose another plan')
        if harmonic * 8 > len(values):
            raise ValueError('Require at least 8 table samples per interference period')
        scale += 0.2
        interference = dict(hz=hz, vpp=0.2, phase_deg=phase, harmonic=harmonic)
        values = [(base['samples'][i] * base['vpp'] if part != 'interference' else 0)
                  / scale + (0.2 / scale * math.sin(math.tau * harmonic * i / len(values)
                             + math.radians(phase)) if part != 'signal' else 0)
                  for i in range(len(values))]
        tones = ([] if part == 'interference' else tones) + ([] if part == 'signal' else [interference])
    if abs(base['offset_v']) + scale / 2 > 5 or scale > 5:
        raise ValueError('Exceeds existing AFG automation voltage envelope')
    if any(not -1 <= value <= 1 for value in values):
        raise ValueError('Normalized sample overflow; no clipping')
    return dict(samples=values, repeat_hz=repeat, vpp=scale, offset_v=base['offset_v'],
                load='HIGHZ', part=part, tones=tones, interference=interference,
                signal_reference=signal_reference,
                output_reference=reference(tones, repeat),
                reference_note='Ideal HIGHZ setting reference, not measured port voltage; C judges signal_reference',
                table_sample_rate_hz=repeat * len(values))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('plan', type=Path)
    parser.add_argument('--save', required=True, type=Path)
    parser.add_argument('--interference-hz', type=float)
    parser.add_argument('--interference-phase-deg', type=float, default=0)
    parser.add_argument('--part', choices=('mixed', 'signal', 'interference'), default='mixed')
    args = parser.parse_args()
    if args.save.exists():
        parser.error('Destination already exists; choose a new file')
    plan = json.loads(args.plan.read_text(encoding='utf-8-sig'))
    result = prepare(plan, interference_hz=args.interference_hz,
                     interference_phase_deg=args.interference_phase_deg, part=args.part)
    # Exclusive create also protects against races and accidental plan overwrite.
    with args.save.open('x', encoding='utf-8') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')
    summary = {key: value for key, value in result.items() if key != 'samples'}
    summary.update(file=str(args.save), points=len(result['samples']), outputs='Not accessed')
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
