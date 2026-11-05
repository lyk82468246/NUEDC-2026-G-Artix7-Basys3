"""Offline 10..50kHz audit; NO hardware and NOT a bit-exact XFFT model.

The ADC-code amplitude/scale only approximate the observed raw amplitude. They
are not a voltage calibration. The isolated 160kHz spur is a hypothesis fixture,
not a claim that the physical setup contains that spur.
"""
import argparse
import json
import math
from pathlib import Path

from reference_model import fft, window_q15


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    q = window_q15()
    delayed_q = [0] + q[:-1]
    cases = []
    for khz in range(10, 51):
        raw = [8 * round(227 * math.sin(math.tau * khz * 1000 * i / 4096045.2)) for i in range(8192)]
        mags = [round(abs(z)) for z in fft([(x*w) >> 15 for x, w in zip(raw, q)])[:4096]]
        delayed = [round(abs(z)) for z in fft([(x*w) >> 15 for x, w in zip(raw, delayed_q)])[:4096]]
        # Independent ideal expectation is ONE known tone at bin 2*khz;
        # do not derive its expected validity from the RTL's own peak logic.
        for mode in (0, 1):
            for name, values in (('ideal_quantized', mags), ('legacy_window_delay', delayed)):
                b = khz*2
                cases.append(dict(kind=name, mode=mode, khz=khz, values=values,
                                  expected=[mode, 1, 1, b, b, 0, 0, values[b], 0, 0]))
            # A narrow interferer above both gates: exact bins, no ADC/FFT model.
            values = [100]*4096
            values[khz*2], values[320] = 1600000, 10000
            order, remainder = divmod(320, khz*2)
            tolerance = order//2+2
            accepted = order > 0 and min(remainder, khz*2-remainder) <= tolerance
            b = khz*2
            cases.append(dict(kind='hypothetical_fixed_spur', mode=mode, khz=khz, values=values,
                              expected=[mode, 2, int(accepted), b if accepted else 0,
                                        b, 320, 0, 1600000, 10000, 0]))
    for i, case in enumerate(cases):
        (output/f'case_{i:03d}.mem').write_text(''.join(f'{v:08x}\n' for v in case.pop('values')))
        (output/f'case_{i:03d}_expected.mem').write_text(''.join(f'{v:08x}\n' for v in case.pop('expected')))
    report = dict(simulated=True, bit_exact_xfft=False, count=len(cases),
                  description='Ideal and delayed-window one-tone expectations plus synthetic narrow-spur cases',
                  hypothetical_spur_hz=160000,
                  cases=cases)
    (output/'manifest.json').write_text(json.dumps(report, indent=2)+'\n')
    print(f'Generated {len(cases)} OFFLINE cases; no USB/JTAG access')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output-dir', type=Path, required=True)
    generate(p.parse_args().output_dir)
