"""Decode an existing ILA CSV without touching hardware or claiming freshness.

Immediate captures describe retained registers; only measurement_valid=1 marks
a completed packet. Diagnostic bit assignments match G_FPGA_Top.v.
"""
import argparse
import csv
import json
from pathlib import Path
from ila_schema import canonical_name


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
            name = canonical_name(name)
            if name in sample:raise ValueError('Ambiguous canonical ILA column: '+name)
            base = 16 if 'HEX' in radix.upper() else 2 if 'BIN' in radix.upper() else 10
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
    fields={'component_count','component_magnitudes','frame_id','calibration_epoch','snapshot_metadata'}
    if fields & samples[-1].keys():
        if not fields <= samples[-1].keys():raise ValueError('Partial debug snapshot schema')
        events=[s for s in samples if s.get('measurement_valid')==1]
        if len(events)!=1:raise ValueError('Debug snapshot requires exactly one fresh event')
        s=events[0];count=s['component_count'];meta=s['snapshot_metadata']
        bins=[(s['diagnostic_bins']>>(12*i))&4095 for i in range(3)]
        mags=[(s['component_magnitudes']>>(32*i))&0xffffffff for i in range(3)]
        if not 0<=count<=3 or any(bins[count:]) or any(mags[count:]):
            raise ValueError('Nonzero unused component slot or invalid count')
        if not meta&1 and (count or s['max_index_out'] or s['amp_f1_out']):
            raise ValueError('Invalid signal retains qualified components')
        if count and (bins[0]!=s['max_index_out'] or mags[0]!=s['amp_f1_out'] or
                      any(bins[i]>=bins[i+1] for i in range(count-1))):
            raise ValueError('Fundamental/component ordering mismatch')
        stable=fields|{'diagnostic_bins','vpp_out','vrms_out','amp_f1_out','max_index_out'}
        event_index=samples.index(s)
        if any(any(row[k]!=s[k] for k in stable) for row in samples[event_index:]):
            raise ValueError('Debug snapshot changed after trigger')
        result['component_snapshot']=dict(schema=2,frame_id=s['frame_id'],
            calibration_epoch=s['calibration_epoch'],signal_valid=bool(meta&1),
            calibration_enabled=bool(meta&2),calibration_present=bool(meta&4),
            mode=(meta>>3)&3,single=bool(meta&32),three_cycles=bool(meta&64),
            count=count,bins=bins,magnitudes_raw=mags)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv', type=Path)
    print(json.dumps(inspect_capture(parser.parse_args().csv), indent=2))
