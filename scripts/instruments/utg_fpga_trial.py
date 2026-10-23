"""Bounded CH1 trial, fixed <=100mVpp envelope; dry-run unless --execute.

Never synthesizes/programs/resets. Uses an already-programmed FPGA and matching
LTX. Uploaded trial table replaces only slot 1 (the prior test TwoTone slot).
All outputs are explicitly disabled in finally; unknown OFF is a hard failure.
"""
import argparse
import json
import math
from pathlib import Path
import time

from analyze_sine_sweep import scale_uv
from hds242s import ROOT, capture_ila, timestamp
from inspect_ila import inspect_capture
from lab_controller import atomic_json
from resource_lock import ResourceLock
from utg932 import UTG932
from utg932_waveform import synthesize_multitone

CASES=('sine','harmonic','strong_harmonic','hf_harmonic','hf_phase',
       'hf_strong_harmonic','offgrid_harmonic')


def fixture(case):
    if case == 'sine':
        tones = [{'hz': 100000, 'vpp': 0.1, 'phase_deg': 0}]
    elif case == 'harmonic':
        tones = [dict(hz=f, vpp=a, phase_deg=0) for f,a in
                 ((50000,0.06),(150000,0.025),(200000,0.015))]
    elif case == 'strong_harmonic':
        tones = [dict(hz=f, vpp=a, phase_deg=p) for f,a,p in
                 ((50000,0.01,0),(150000,0.05,90),(200000,0.04,0))]
    elif case in ('hf_harmonic','hf_phase','hf_strong_harmonic','offgrid_harmonic'):
        base=124750 if case=='offgrid_harmonic' else 125000
        amplitudes=(0.01,0.05,0.04) if case=='hf_strong_harmonic' else (0.06,0.025,0.015)
        phases=(0,90,0) if case in ('hf_phase','hf_strong_harmonic') else (0,0,0)
        tones=[dict(hz=base*h,vpp=a,phase_deg=p) for h,a,p in zip((1,3,4),amplitudes,phases)]
    else:
        raise ValueError('Unknown fixed trial')
    points=1000 if case.startswith('hf_') or case=='offgrid_harmonic' else 4000
    table = synthesize_multitone(dict(points=points, vpp=0.1, offset_v=0, tones=tones))
    # Dense continuous-function reference, not just extrema of the 4000-point
    # upload. Does not model generator interpolation, analog phase or loading.
    values = [math.fsum(t['vpp']/2*math.sin(2*math.pi*t['harmonic']*i/65536+
              math.radians(t['phase_deg'])) for t in table['tones']) for i in range(65536)]
    reference = dict(vpp_mv=(max(values)-min(values))*1000,
                     rms_mv=math.sqrt(sum((t['vpp']/2)**2 for t in tones)/2)*1000,
                     fundamental_peak_mv=tones[0]['vpp']*500,
                     fundamental_hz=tones[0]['hz'],
                     component_peak_mv=[t['vpp']*500 for t in tones],
                     component_hz=[t['hz'] for t in tones],
                     frequency_tolerance_hz=250 if case=='offgrid_harmonic' else 0,
                     # Lower grid indices are only descriptive for off-grid
                     # tones; acceptance uses component_hz and explicit bound.
                     bins=[int(t['hz']/500) for t in tones])
    return table,reference


def signature(state):
    return {k:state.get(k) for k in ('waveform','mode','unit','load_ohm','hz',
                                   'vpp','offset_v','phase_deg','arb_source','arb_slot')}


def archive_sessions(directories, output):
    """Compact, provenance-labelled results; never hides failed/OFF-unknown runs."""
    output=Path(output)
    if output.exists():raise FileExistsError(output)
    sessions=[]
    for directory in directories:
        path=Path(directory)/'session.json'
        source=json.loads(path.read_text(encoding='utf-8'))
        sessions.append({**{k:source.get(k) for k in ('case','status','identity','started','finished',
                        'reference','gains','reference_kind','output_off_confirmed','error')},
                         'source_session':str(path.resolve()),'captures':source['captures']})
    all_components=bool(sessions) and all(bool(s['captures']) and
        all(c['analysis'].get('all_component_amplitudes_observed',False) for c in s['captures']) for s in sessions)
    value=dict(sessions=sessions,
               pass_scope=('Vpp_RMS_all_component_peaks_candidate_frequencies' if all_components else
                           'Vpp_RMS_fundamental_peak_candidate_frequencies_only'),
               absolute_input_calibrated=False,
               all_component_amplitudes_observed=all_components,
               overall_pass=bool(sessions) and all(s['status']=='completed' and
                   s['output_off_confirmed'] and bool(s['captures']) and
                   all(c['analysis']['nominal_consistency_pass'] for c in s['captures']) for s in sessions))
    # Exclusive creation: this archive is evidence, not mutable live state.
    with output.open('x',encoding='utf-8') as stream:json.dump(value,stream,indent=2)
    return value


def evaluate(raw, inspected, reference, gains):
    d=inspected['diagnostic']
    measured={k:scale_uv(raw[r],gains[k])/1000 for k,r in
              (('vpp','vpp_out'),('rms','vrms_out'),('fft','amp_f1_out'))}
    expected=dict(vpp=reference['vpp_mv'],rms=reference['rms_mv'],
                  fft=reference['fundamental_peak_mv'])
    errors={k:measured[k]-expected[k] for k in measured}
    bins=[x for x in inspected['candidate_bins'] if x]
    tolerance=reference.get('frequency_tolerance_hz',0)
    if type(tolerance) not in (int,float) or not math.isfinite(tolerance) or not 0<=tolerance<=250:
        raise ValueError('Trial frequency tolerance must be 0..250 Hz')
    expected_hz=reference.get('component_hz',[b*500 for b in reference['bins']])
    frequency_errors=[b*500-f for b,f in zip(bins,expected_hz)]
    frequency_match=(len(bins)==len(expected_hz) and all(abs(e)<=tolerance for e in frequency_errors))
    valid=(inspected['completed_packet_samples']==1 and d['controls']==4 and
           d['signal_valid'] and d['error_code']==0 and not d['acquisition_fault'] and
           all(inspected['last_registers'][k]==raw[k] for k in
               ('vpp_out','vrms_out','amp_f1_out','max_index_out')) and
           frequency_match and abs(raw['frequency_hz']-reference['fundamental_hz'])<=tolerance and
           raw['max_index_out']*500==raw['frequency_hz'])
    snapshot=inspected.get('component_snapshot')
    component_measurements=None
    component_errors=None
    components_pass=True
    if snapshot is not None:
        component_measurements=[scale_uv(x,gains['fft'])/1000 for x in snapshot['magnitudes_raw'][:snapshot['count']]]
        component_errors=[a-b for a,b in zip(component_measurements,reference['component_peak_mv'])]
        components_pass=(snapshot['count']==len(reference['bins']) and
                         snapshot['signal_valid'] and snapshot['mode']==1 and
                         snapshot['bins'][:snapshot['count']]==bins and frequency_match and
                         all(abs(e)<=5 for e in component_errors))
    return dict(validity_pass=valid, nominal_consistency_pass=valid and components_pass and
                all(abs(e)<=5 for e in errors.values()), candidate_bins=bins,
                reference_mv=measured, errors_mv=errors,
                absolute_input_calibrated=False, runtime_vio_measurement=False,
                all_component_amplitudes_observed=snapshot is not None,
                component_reference_mv=component_measurements,component_errors_mv=component_errors,
                component_frequency_errors_hz=frequency_errors,frequency_tolerance_hz=tolerance,
                frame_id=snapshot['frame_id'] if snapshot else None,
                calibration_epoch=snapshot['calibration_epoch'] if snapshot else None)


def run(case, directory, vivado, ltx, captures=2):
    directory=Path(directory)
    # Do not relabel somebody else's existing result if setup refuses reuse.
    if directory.exists():raise FileExistsError(directory)
    try:
        return _run(case,directory,vivado,ltx,captures)
    except BaseException as error:
        path=directory/'session.json'
        if path.is_file():
            report=json.loads(path.read_text(encoding='utf-8'))
            if report['status']=='running':
                report.update(status='failed',error=str(error),finished=timestamp())
                atomic_json(path,report)
        raise


def _run(case, directory, vivado, ltx, captures=2):
    if type(captures)!=int or not 1<=captures<=3:raise ValueError('Expected 1..3 captures')
    table,reference=fixture(case)
    if not Path(vivado).is_file() or not Path(ltx).is_file():raise ValueError('Missing Vivado/LTX')
    profile=json.loads((ROOT/'docs/calibration_generator_nominal_20261023/calibration.json').read_text())
    if profile['reference']!='generator_HIGHZ_display_setting_only':raise ValueError('Wrong reference profile')
    gains={k:profile['fits'][k]['gain_q16'] for k in ('vpp','rms','fft')}
    directory=Path(directory);directory.mkdir(parents=True,exist_ok=False)
    report=dict(case=case,status='running',started=timestamp(),reference=reference,
                gains=gains, captures=[],reference_kind='UTG_HIGHZ_setting_provisional_HDS_gains',
                simulated=False,output_off_confirmed=False)
    def save():atomic_json(directory/'session.json',report)
    save()
    with ResourceLock(ROOT/'.lab_locks/lab_service.lock'), UTG932() as generator:
        report['identity']=generator.identity
        try:
            before={str(ch):generator.settings(ch) for ch in (1,2)}
            report['initial']=before;save()
            if any(s['output'] for s in before.values()):
                raise RuntimeError('Expected both outputs initially OFF; no automatic ON retry')
            if case=='sine':
                configured=generator.configure_sine(dict(hz=100000,vpp=0.1,offset_v=0),1)
            else:
                atomic_json(directory/'waveform.json',table)
                report['upload']=generator.upload_arb(table['samples'],slot=1,name='FpgaTrial')
                configured=generator.configure_arb(1,slot=1,hz=table['repeat_hz'],vpp=0.1,offset_v=0,load='HIGHZ')
            report['configured']=configured;save()
            state=generator.settings(1)
            if (state['output'] or state['vpp']!=0.1 or state['offset_v']!=0 or
                    state['load_ohm']!=10000 or generator.settings(2)['output']):
                raise RuntimeError('Safe-envelope readback mismatch')
            expected_signature=signature(state)
            generator.output_on(1);report['output_started']=timestamp();save()
            time.sleep(2)
            for number in range(captures):
                state=generator.settings(1)
                if not state['output'] or signature(state)!=expected_signature:
                    raise RuntimeError('Generator state changed before capture')
                subdir=directory/f'frame_{number:02d}';subdir.mkdir()
                raw=capture_ila(vivado,subdir,ltx)
                inspected=inspect_capture(subdir/'ila.csv')
                state=generator.settings(1)
                if not state['output'] or signature(state)!=expected_signature or generator.settings(2)['output']:
                    raise RuntimeError('Generator state changed during capture; frame not accepted')
                verdict=evaluate(raw,inspected,reference,gains)
                if report['captures'] and verdict.get('frame_id') is not None:
                    previous=report['captures'][-1]['analysis']
                    if verdict['frame_id']==previous.get('frame_id'):
                        raise RuntimeError('Repeated debug frame ID; frame not accepted')
                    if verdict['calibration_epoch']!=previous.get('calibration_epoch'):
                        raise RuntimeError('Calibration epoch changed within trial; do not mix versions')
                frame=dict(raw=raw,inspection=inspected,analysis=verdict,time=timestamp())
                atomic_json(subdir/'result.json',frame);report['captures'].append(frame);save()
                if not verdict['nominal_consistency_pass']:
                    raise RuntimeError('Trial mismatch; do not continue to another waveform without analysis')
            report['status']='completed'
        except BaseException as error:
            report.update(status='failed',error=str(error));raise
        finally:
            shutdown={str(ch):generator.emergency_off(ch) for ch in (1,2)}
            report['shutdown']=shutdown
            report['output_off_confirmed']=all(s['acknowledged'] for s in shutdown.values())
            report['scpi_log']=list(generator.log);report['finished']=timestamp()
            if not report['output_off_confirmed']:
                report['status']='failed';report['shutdown_error']='Manually disable BOTH outputs; OFF unconfirmed'
            save()
            if not report['output_off_confirmed']:raise RuntimeError(report['shutdown_error'])
    return report


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--case',choices=CASES,required=True)
    p.add_argument('--directory',type=Path)
    p.add_argument('--vivado',default='C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat')
    p.add_argument('--ltx',default=str(ROOT/'G_FPGA.runs/impl_1/G_FPGA_Top.ltx'))
    p.add_argument('--execute',action='store_true')
    a=p.parse_args()
    if not a.execute:
        table,ref=fixture(a.case)
        print(json.dumps(dict(dry_run=True,case=a.case,reference=ref,
                              scale_vpp=table['vpp'],repeat_hz=table['repeat_hz']),indent=2));return
    if a.directory is None:p.error('--directory is required for execution')
    r=run(a.case,a.directory,a.vivado,a.ltx)
    print(json.dumps({k:r[k] for k in ('case','status','output_off_confirmed')},indent=2))


if __name__=='__main__':main()
