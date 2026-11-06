import sys,os,json,time,subprocess,math
from pathlib import Path
root=Path.cwd();sys.path.insert(0,str(root/'scripts/instruments'))
from afg1022 import AFG1022
from inspect_ila import inspect_capture
from resource_lock import ResourceLock
from fit_amplitude_calibration import fit_pairs
from runtime_vio import run as vio_run
out=root/'test_results/afg_calibration_20261106';vr='C:/AMDDesignTools/2025.2/Vivado';ltx=root/'G_FPGA.runs/impl_1/debug_nets.ltx'
env=os.environ.copy();env.update(XILINX_VIVADO=vr,PROCESSOR_ARCHITECTURE='AMD64',XILINX_LOCAL_USER_DATA='NO');env['PATH']=';'.join([vr+'/lib/win64.o',vr+'/bin',vr+'/bin/unwrapped/win64.o',env['PATH']])
print('INITIAL_BANK',vio_run(vr+'/bin/vivado.bat',ltx,out/'initial_bank','inspect'),flush=True)
rows=[]
with AFG1022() as d:
 try:
  d.output_off(2)
  points=[('fit',100000,v) for v in [.1,.15,.2,.25]]+[('verify',100000,v) for v in [.125,.225]]+[('frequency',hz,.2) for hz in [10000,200000]]
  for index,(kind,hz,vpp) in enumerate(points):
   before=d.output_on(1,waveform='sine',hz=hz,vpp=vpp,offset_v=0,load='HIGHZ');time.sleep(2)
   name=f'{index:02}_{kind}_{hz}_{vpp}';csv=out/(name+'.csv')
   print('MEASURING',name,flush=True)
   with ResourceLock(root/'.lab_locks/fpga_ila.lock'),(out/(name+'.console.txt')).open('w') as log:
    p=subprocess.run([vr+'/bin/vivado.bat','-mode','batch','-nojournal','-log',str(out/(name+'.log')),'-source',str(root/'scripts/capture_hw_ila.tcl'),'-tclargs',str(csv),str(ltx)],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=150)
   if p.returncode:raise RuntimeError('Capture failed: '+name)
   after=d.settings(1)
   if before!=after:raise RuntimeError('Source state changed')
   i=inspect_capture(csv);c=i['candidate_snapshot']; raw=i['last_registers']
   if i['completed_packet_samples']!=1 or not c['qualified'] or c['count']!=1 or abs(c['bins'][0]*500-hz)>500:raise RuntimeError('Not a fresh clean sine: '+name+' '+str(c))
   row=dict(kind=kind,hz=hz,vpp=vpp,source_before=before,source_after=after,ila=i,csv=csv.name)
   rows.append(row);(out/'measurements.json').write_text(json.dumps(rows,indent=2))
   print('RAW',name,raw['vpp_out'],raw['vrms_out'],raw['amp_f1_out'],flush=True)
 finally:
  d.output_off(1);d.output_off(2);print('OUTPUTS_OFF',d.settings(1)['output'],d.settings(2)['output'],flush=True)
fits={}
for name,field,factor in [('vpp','vpp_out',1),('rms','vrms_out',1/(2*math.sqrt(2))),('fft','amp_f1_out',.5)]:
 fits[name]=fit_pairs([(r['ila']['last_registers'][field],r['vpp']*1e6*factor) for r in rows if r['kind']=='fit'])
for r in rows:
 r['errors_uv']={name:r['ila']['last_registers'][field]*fits[name]['gain_q16']/65536-r['vpp']*1e6*factor for name,field,factor in [('vpp','vpp_out',1),('rms','vrms_out',1/(2*math.sqrt(2))),('fft','amp_f1_out',.5)]}
result=dict(reference='AFG1022_HIGHZ_display_setting',absolute_input_calibrated=False,outputs_off=True,fits=fits,measurements=rows)
(out/'calibration.json').write_text(json.dumps(result,indent=2));print('FITS',json.dumps(fits),flush=True)
# Apply only after clean measurements and held-out checks; no flash save here.
if any(abs(e)>5000 for r in rows if r['kind']=='verify' for e in r['errors_uv'].values()):raise RuntimeError('Held-out error >5mV: do not apply')
gains=[fits[k]['gain_q16'] for k in ['vpp','rms','fft']]
print('APPLY',vio_run(vr+'/bin/vivado.bat',ltx,out/'apply','apply',gains,1),flush=True)
print('APPLIED_BANK',vio_run(vr+'/bin/vivado.bat',ltx,out/'applied_bank','inspect'),flush=True)
