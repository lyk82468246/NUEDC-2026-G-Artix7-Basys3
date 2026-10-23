"""OFFLINE ONLY: provisional front-end fit and 95-tap FIR feasibility study.

Requires NumPy, not SciPy. NEVER touches Vivado, instruments or production COE.
Amplitude observations use generator-setting reference. Effective capacitance
and minimum-phase response are a model hypothesis, not measured components or
phase calibration. Candidate files are experiments, NOT production settings.
"""
import argparse
import hashlib
import json
import math
import platform
from pathlib import Path
import numpy as np
from reference_model import FS, N, Tone, RAW_PER_MV, cases, normalize, window_q15

ROOT=Path(__file__).resolve().parents[2]


def frontend(f, cap_pf=22.0):
    if not math.isfinite(cap_pf) or cap_pf<=0:raise ValueError('Positive finite capacitance required')
    f=np.asarray(f,dtype=float)
    return (1+3.6/(1+2j*np.pi*f*3600*cap_pf*1e-12))**2


def normalized_frontend(f,cap_pf):
    # Remove scalar amplitude only. Preserve the circuit's phase hypothesis.
    return frontend(f,cap_pf)/abs(frontend(100000,cap_pf))


def dc_response(f):
    # AFE uses previous state for y[n]=x[n]-d[n], then updates the Q16 state.
    z=np.exp(-2j*np.pi*np.asarray(f)/FS)
    return (1-z)/(1-(1-2**-12)*z)


def dc_fixed(raw):
    state=0
    result=np.empty(len(raw),dtype=np.int64)
    clipped=False
    for k,x in enumerate(raw):
        x=int(x)
        y=x-(state>>16)
        clipped|=not -32768<=y<=32767
        result[k]=max(-32768,min(32767,y))
        state+=((x<<16)-state)>>12
    return result,clipped


def load_base():
    text=(ROOT/'sources/coeffs/fir_lp_600k_95t.coe').read_text(encoding='utf-8')
    vector=text.split('memory_initialization_vector=',1)[1].split(';',1)[0]
    return np.array([round(float(x.strip())*32768) for x in vector.split(',')],dtype=np.int64)


def response(q,f):
    f=np.atleast_1d(f)
    return np.exp(-2j*np.pi*f[:,None]*np.arange(len(q))[None,:]/FS)@(np.asarray(q)/32768)


def fit_frontend(report):
    if report.get('absolute_input_calibrated') is not False:
        raise ValueError('Expected explicitly provisional reference')
    rows=report['records']
    f=[];observed=[]
    for r in rows:
        if not r['frequency_validity_pass'] or r.get('controls')!=4:
            raise ValueError('Need valid B-mode records')
        pp=r['settings']['vpp']*1000
        for key,ref in [('rms',pp/(2*math.sqrt(2))),('fft',pp/2)]:
            f.append(r['settings']['hz'])
            observed.append(r['postprocessed_reference_mv'][key]/ref)
    f=np.array(f);observed=np.array(observed)
    if not np.all(np.isfinite(observed)) or not np.all(observed>0):
        raise ValueError('Positive finite measured amplitudes required')
    if len(set(f))<3:raise ValueError('At least three distinct fitted frequencies required')
    best=None
    for cap in np.linspace(15,35,4001):
        shape=abs(normalized_frontend(f,cap))
        scalar=float(shape@observed/(shape@shape))
        error=float(np.mean((scalar*shape-observed)**2))
        if best is None or error<best[0]:best=(error,float(cap),scalar,scalar*shape-observed)
    return {'effective_capacitance_pf':best[1], 'nuisance_scalar':best[2],
            'rms_fit_residual_relative':math.sqrt(best[0]),
            'max_fit_residual_relative':float(max(abs(best[3]))),
            'phase_measured':False,
            'warning':'Effective model fit, not identified physical capacitance; scalar is NOT inserted into FIR or production gains'}


def design(cap_pf,phase_equalize=True,taps=95):
    if taps!=95:raise ValueError('This experiment is explicitly limited to existing 95 taps')
    # Include transition constraints to control unconstrained out-of-band gain.
    f=np.concatenate([np.linspace(0,600000,601),np.linspace(601000,899000,299),
                      np.linspace(900000,FS/2,1150)])
    lp=np.where(f<=600000,1,np.where(f>=900000,0,
                .5*(1+np.cos(np.pi*(f-600000)/300000))))
    h=normalized_frontend(f,cap_pf)
    inv=1/h if phase_equalize else 1/abs(h)
    target=lp*inv*np.exp(-2j*np.pi*f*((taps-1)/2)/FS)
    weight=np.where(f<=600000,1,np.where(f>=900000,20,.3))
    a=np.exp(-2j*np.pi*f[:,None]*np.arange(taps)[None,:]/FS)
    if not phase_equalize:
        # Force exact symmetric coefficients, not just numerical symmetry.
        folding=np.zeros((taps,(taps+1)//2))
        for k in range((taps+1)//2):
            folding[k,k]=1
            folding[taps-1-k,k]=1
        a=a@folding
    weighted=a*weight[:,None]
    b=target*weight
    real=np.linalg.lstsq(np.vstack([weighted.real,weighted.imag]),
                         np.concatenate([b.real,b.imag]),rcond=None)[0]
    if not phase_equalize:real=folding@real
    quant=np.rint(real*32768).astype(np.int64)
    if min(quant)<-32768 or max(quant)>32767:
        raise ValueError('Coefficient overflow: candidate not Q1.15 representable')
    return quant


def frequency_metrics(q,cap_pf):
    f=np.linspace(10000,500000,1961)
    total=normalized_frontend(f,cap_pf)*response(q,f)*dc_response(f)*np.exp(2j*np.pi*f*47/FS)
    omega=2*np.pi*f/FS
    phase=np.unwrap(np.angle(total))
    extra_delay=-float(omega@phase/(omega@omega))
    stop=np.linspace(900000,FS/2,4593)
    return {'max_passband_amplitude_error_relative':float(max(abs(abs(total)-1))),
            'max_residual_phase_rad_after_common_delay':float(max(abs(np.angle(total)))),
            'best_fit_extra_delay_samples':extra_delay,
            'max_nonlinear_phase_rad_after_fitted_delay':float(max(abs(phase+omega*extra_delay))),
            'digital_stopband_peak_db':float(20*np.log10(max(abs(response(q,stop))))),
            'digital_1mhz_db':float(20*np.log10(abs(response(q,[1000000])[0]))),
            'sum_q15':int(sum(q)),'sum_abs_coefficients':float(sum(abs(q))/32768),
            'symmetric':bool(np.array_equal(q,q[::-1]))}


def samples(tones,indices,transfer=None):
    result=np.zeros(len(indices))
    for t in tones:
        h=1 if transfer is None else complex(transfer(t.hz))
        result+=t.peak_mv*abs(h)*np.sin(2*np.pi*t.hz*indices/FS+t.phase+np.angle(h))
    return result


def run_case(name,tones,q,cap_pf,allpass_tau=0,interference=None):
    # Analog steady state is evaluated before sampling. Full prehistory avoids
    # falsely attributing FIR startup transient to 8192-point measurement error.
    def analog(f):
        h=normalized_frontend(f,cap_pf)
        if allpass_tau:
            s=2j*np.pi*f*allpass_tau
            h=h*(1-s)/(1+s)  # same amplitude, different unmeasured phase
        return h
    warmup=16*4096 # IIR startup is NOT a settled-frame measurement.
    extra=1024 # >= two periods at minimum legal 10kHz
    indices=np.arange(-warmup-len(q)+1,N+extra)
    mixed=tones+([] if interference is None else [interference])
    analog_mv=samples(mixed,indices,analog)
    codes=np.rint(analog_mv*RAW_PER_MV/16)+2048
    adc_clipped=bool(np.any((codes<0)|(codes>4095)))
    raw=(np.clip(codes,0,4095).astype(np.int64)-2048)*16
    acc=np.convolve(raw,q,mode='valid')
    filtered=acc>>15 # signed truncation hypothesis, NOT bit-exact FIR IP proof
    fir_clipped=bool(np.any((filtered<-32768)|(filtered>32767)))
    filtered=np.clip(filtered,-32768,32767)
    filtered,dc_clipped=dc_fixed(filtered)
    crossings=np.flatnonzero((filtered[warmup-1:warmup+extra-1]<=0)&
                            (filtered[warmup:warmup+extra]>0))
    if not len(crossings):raise ValueError('No positive zero crossing after warmup')
    start=int(crossings[0])
    filtered=filtered[warmup+start:warmup+start+N]
    output=filtered/RAW_PER_MV
    ideal=samples(tones,np.arange(N)+start-47)
    vpp_error=float((max(output)-min(output))-(max(ideal)-min(ideal)))
    rms_raw=math.isqrt(int(np.sum(filtered*filtered))//N)
    rms_error=float(rms_raw/RAW_PER_MV-np.sqrt(np.mean(ideal**2)))
    w=np.array(window_q15(),dtype=np.int64)
    win=(filtered*w)>>15
    mags=abs(np.fft.rfft(win))
    peak_errors=[]
    for tone in tones:
        k=int(round(tone.hz*N/FS))
        # max over local mainlobe handles half-bin and slight peak location shift.
        peak=2*max(mags[max(0,k-2):min(len(mags),k+3)])/(sum(w)/32768)/RAW_PER_MV
        peak_errors.append(float(peak-tone.peak_mv))
    return {'name':name,'vpp_error_mv':vpp_error,'rms_error_mv':rms_error,
            'component_peak_errors_mv':peak_errors,'adc_clipped':adc_clipped,
            'fir_clipped':fir_clipped,'extra_allpass_tau_s':allpass_tau,
            'dc_clipped':dc_clipped,'capture_start_sample':start,
            'within_5mv_in_this_model':not adc_clipped and not fir_clipped and not dc_clipped and
                max([abs(vpp_error),abs(rms_error)]+[abs(x) for x in peak_errors])<=5}


def study(output):
    report=json.loads((ROOT/'docs/b_band_20261023_analysis.json').read_text(encoding='utf-8'))
    fit=fit_frontend(report);cap=fit['effective_capacitance_pf']
    filters={'original':load_base(),'amplitude_only':design(cap,False),'complex_inverse':design(cap,True)}
    testcases=[(name,tones) for name,_,tones in cases()]
    # Stress the legal upper band at full 250mVpp with independent phases.
    for p3,p4 in [(0,0),(.7,1.2),(1.3,.7),(math.pi/2,-math.pi/2)]:
        tones=normalize([Tone(125000,1),Tone(375000,.5,p3),Tone(500000,.3,p4)],250)
        testcases.append((f'B_250mV_phase_{p3:.3f}_{p4:.3f}',tones))
    for hz in [10000,100000,250000,375000,499750,500000]:
        testcases.append((f'sine_{hz}_250mV',[Tone(hz,125)]))
    testcases.append(('B_high_strong_harmonic',normalize(
        [Tone(125000,.2),Tone(375000,1,.7),Tone(500000,.8,1.2)],250)))
    testcases.append(('B_high_offbin',normalize(
        [Tone(124875,1),Tone(374625,.5,.7),Tone(499500,.3,1.2)],250)))
    results={}
    for label,q in filters.items():
        results[label]={'frequency':frequency_metrics(q,cap),
                        'cases':[run_case(name,tones,q,cap) for name,tones in testcases]}
    phase_cases=[run_case(name,tones,filters['complex_inverse'],cap,allpass_tau=.5e-6)
                 for name,tones in testcases if name.startswith('B_250mV_phase')]
    mismatches={str(c):[run_case(name,tones,filters['complex_inverse'],c)
                        for name,tones in testcases] for c in [22,cap*.9,cap*1.1]}
    ub=normalize([Tone(125000,1),Tone(375000,.5,.7),Tone(500000,.3,1.2)],250)
    interference={str(f):run_case(f'C_model_{f}',ub,filters['complex_inverse'],cap,
                                   interference=Tone(f,100)) for f in [1000000,4000000]}
    result={'simulated':True,'hardware_validated':False,'phase_measured':False,
            'python_version':platform.python_version(),'numpy_version':np.__version__,
            'input_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in
                ['sources/coeffs/fir_lp_600k_95t.coe','docs/b_band_20261023_analysis.json']},
            'fit':fit,'filter_results':results,'same_amplitude_different_phase_counterexamples':phase_cases,
            'model_mismatch_cases':mismatches,'interference_cases':interference,
            'notes':['Generator setting reference, no independent input voltage calibration',
                     '95 real taps Q1.15; FIR arithmetic/ADC scale are synthetic assumptions',
                     'AFE Q16 DC estimator shift12, 16 time constants warmup, positive-zero-cross frame, integer mean-square/sqrt modeled',
                     'Complex inverse targets analog model; slow DC-remover phase is not separately inverted',
                     'No production coefficient, RTL, IP, or hardware changes',
                     'All-pass is an identifiability counterexample, NOT claimed actual circuit',
                     'No finite sampled frequency grid proves continuous-band worst case',
                     'No general C-mode pass: already-aliased interference remains in band']}
    output=Path(output);output.mkdir(parents=True,exist_ok=False)
    for label,q in filters.items():
        if label=='original':continue
        text='; OFFLINE CANDIDATE ONLY, NOT PRODUCTION\n'
        text+='memory_initialization_radix=10;\nmemory_initialization_vector=\n'
        text+=',\n'.join(f'{int(x)/32768:.12f}' for x in q)+';\n'
        (output/f'{label}_95t_q15.coe').write_text(text,encoding='ascii')
    (output/'study.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    summary={k:{'frequency':v['frequency'],'max_vpp_error_mv':max(abs(c['vpp_error_mv']) for c in v['cases']),
                'all_model_cases_pass':all(c['within_5mv_in_this_model'] for c in v['cases'])}
             for k,v in results.items()}
    print(json.dumps({'fit':fit,'summary':summary,
                     'phase_counterexample_max_vpp_error':max(abs(x['vpp_error_mv']) for x in phase_cases),
                     'interference':interference},indent=2))
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    study(parser.parse_args().output)
