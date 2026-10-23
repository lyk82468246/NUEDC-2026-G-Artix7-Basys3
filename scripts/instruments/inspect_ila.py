"""Decode an existing ILA CSV without touching hardware or claiming freshness.

Immediate captures describe retained registers; only measurement_valid=1 marks
a completed packet. Diagnostic bit assignments match G_FPGA_Top.v.
"""
import argparse
import csv
import json
from pathlib import Path


def inspect_capture(path):
    with Path(path).open(newline='', encoding='utf-8-sig') as stream:
        rows = list(csv.reader(stream))
    if len(rows) < 3:
        raise ValueError('No captured samples')
    headers, radices = rows[:2]
    samples = []
    for row in rows[2:]:
        if not row:
            continue
        sample = {}
        for name, radix, value in zip(headers, radices, row):
            name = name.split('[')[0]
            base = 16 if 'HEX' in radix.upper() else 2 if 'BINARY' in radix.upper() else 10
            sample[name] = int(value, base)
        samples.append(sample)
    if not samples:
        raise ValueError('No captured samples')
    result = {'samples': len(samples),
              'completed_packet_samples': sum(s.get('measurement_valid', 0) == 1 for s in samples),
              'last_registers': samples[-1]}
    status = samples[-1].get('diagnostic_status')
    if status is not None:
        result['diagnostic'] = {
            'error_code': (status >> 28) & 15,
            'run_state': (status >> 25) & 7,
            'controls': (status >> 20) & 31,
        }
        names = ['capture_enable', 'controller_release', 'capture_start', 'frame_valid',
                 'time_result_valid', 'fft_result_valid', 'peak_result_valid', 'signal_valid',
                 'capture_busy', 'calc_busy', 'fft_busy', 'peak_busy', 'hmi_busy',
                 'packet_finished', 'acquisition_fault']
        result['diagnostic'].update({name: bool(status & (1 << (19-i)))
                                     for i, name in enumerate(names)})
        result['diagnostic']['events_since_frame_start'] = {
            name: bool(status & (1 << (4-i))) for i, name in enumerate(
                ['frame_complete', 'time_complete', 'fft_complete', 'peak_complete', 'measurement_snapshot'])}
    adc = [s['diagnostic_adc'] for s in samples if 'diagnostic_adc' in s]
    if adc:
        result['adc_window'] = {'min': min(adc), 'max': max(adc)}
    bins = samples[-1].get('diagnostic_bins')
    if bins is not None:
        result['candidate_bins'] = [(bins >> (12*i)) & 4095 for i in range(3)]
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv', type=Path)
    print(json.dumps(inspect_capture(parser.parse_args().csv), indent=2))
