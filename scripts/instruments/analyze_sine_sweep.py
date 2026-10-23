"""Read-only sweep analysis with fresh-ILA validation and explicit units.

Reconstructs calibrated reference values from RAW with the saved gain profile;
these are NOT new VIO reads and NOT independent voltage accuracy measurements.
Default sign-off requires completed hardware sine plans with HIGHZ and zero DC.
Explicit failed-plan review preserves failure status and never signs it off.
"""
import argparse
import json
import math
from pathlib import Path
from inspect_ila import inspect_capture


def scale_uv(raw, gain):
    if type(raw)!=int or type(gain)!=int or not 0<=raw<=0xffffffff or not 0<=gain<=0xffffffff:
        raise ValueError('uint32 raw/gain required')
    return min(0xffffffff,(raw*gain+32768)>>16)


def analyze(plan_dir, profile, include_failed_plan=False):
    plan_dir=Path(plan_dir)
    plan=json.loads((plan_dir/'plan.json').read_text(encoding='utf-8'))
    job=json.loads((plan_dir/'job.json').read_text(encoding='utf-8'))
    if (job.get('status')!='completed' and not (include_failed_plan and job.get('status')=='failed')) or job.get('simulated') is not False:
        raise ValueError('Only completed hardware plans can be signed off')
    if plan.get('load')!='HIGHZ':raise ValueError('Expected HIGHZ reference')
    if profile.get('reference')!='generator_HIGHZ_display_setting_only':
        raise ValueError('Unexpected profile reference; do not silently mix actual/reference volts')
    gains={k:profile['fits'][k]['gain_q16'] for k in ('vpp','rms','fft')}
    rows=[]
    for point, settings in enumerate(plan['points']):
        if settings['offset_v']!=0 or not 0<settings['vpp']<=0.1:
            raise ValueError('Outside tested sine voltage/DC contract')
        for sample in range(plan.get('samples_per_point',1)):
            directory=plan_dir/f'point_{point:03d}_sample_{sample:02d}'
            r=json.loads((directory/'result.json').read_text(encoding='utf-8'))
            if (r.get('simulated') is not False or r.get('status')!='completed' or
                    r.get('settings')!=settings or r.get('point')!=point or r.get('sample')!=sample):
                raise ValueError('Missing/misassociated hardware record')
            i=inspect_capture(directory/'ila.csv')
            f=r['fpga']
            if i['completed_packet_samples']!=1:
                raise ValueError('Not exactly one fresh measurement snapshot')
            if any(i['last_registers'][k]!=f[k] for k in ('vpp_out','vrms_out','amp_f1_out','max_index_out')):
                raise ValueError('ILA raw registers differ from plan result')
            if f['frequency_hz']!=f['max_index_out']*500:
                raise ValueError('Frequency/index mismatch')
            measured={k:scale_uv(f[raw],gains[k])/1000 for k,raw in
                      (('vpp','vpp_out'),('rms','vrms_out'),('fft','amp_f1_out'))}
            pp=settings['vpp']*1000
            expected={'vpp':pp,'rms':pp/(2*math.sqrt(2)),'fft':pp/2}
            errors={k:measured[k]-expected[k] for k in measured}
            frequency_error=f['frequency_hz']-settings['hz']
            d=i['diagnostic']
            accepted=(d['signal_valid'] and d['error_code']==0 and
                      sum(k!=0 for k in i['candidate_bins'])==1 and abs(frequency_error)<=1000)
            rows.append({'point':point,'sample':sample,'settings':settings,'raw':f,
                         'candidate_bins':i['candidate_bins'],'signal_valid':d['signal_valid'],
                         'error_code':d['error_code'],'fresh_event_count':i['completed_packet_samples'],
                         'frequency_error_hz':frequency_error,
                         'postprocessed_reference_mv':measured,
                         'nominal_reference_errors_mv':errors,
                         'frequency_validity_pass':accepted,
                         'nominal_amplitude_consistency_pass':all(abs(x)<=5 for x in errors.values())})
    if not rows:raise ValueError('Empty plan')
    return {'schema':1,'source_plan':str(plan_dir.resolve()),
            'source_job_status':job['status'],'source_job_error':job.get('error'),
            'overall_transaction_pass':job['status']=='completed' and all(r['frequency_validity_pass'] for r in rows),
            'reference':profile['reference'],'absolute_input_calibrated':False,
            'runtime_vio_measurement':False,
            'note':'Amplitude values reconstructed from raw, saved provisional profile; not independent accuracy proof',
            'max_abs_frequency_error_hz':max(abs(r['frequency_error_hz']) for r in rows),
            'frequency_validity_pass':all(r['frequency_validity_pass'] for r in rows),
            'nominal_amplitude_consistency_pass':all(r['nominal_amplitude_consistency_pass'] for r in rows),
            'max_abs_nominal_amplitude_error_mv':{k:max(abs(r['nominal_reference_errors_mv'][k]) for r in rows) for k in gains},
            'records':rows}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('plan',type=Path)
    p.add_argument('--profile',type=Path,default=Path('docs/calibration_generator_nominal_20261023/calibration.json'))
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--include-failed-plan',action='store_true',help='Review all completed sample files, but preserve failed source status and overall_transaction_pass=false')
    a=p.parse_args()
    result=analyze(a.plan,json.loads(a.profile.read_text(encoding='utf-8')),a.include_failed_plan)
    with a.output.open('x',encoding='utf-8') as stream:json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='records'},indent=2))


if __name__=='__main__':main()
