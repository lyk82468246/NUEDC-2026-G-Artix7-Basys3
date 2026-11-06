import sys,json,math,re,time
from pathlib import Path
root=Path.cwd();sys.path.insert(0,str(root/'scripts/instruments'))
from afg1022 import AFG1022
from runtime_vio import run
out=root/'test_results/afg_calibration_20261106'; c=json.loads((out/'calibration.json').read_text());g=[c['fits'][k]['gain_q16'] for k in ('vpp','rms','fft')]
vr='C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat';ltx=root/'G_FPGA.runs/impl_1/debug_nets.ltx'
# Caller runs only after the acquisition/apply process succeeded.
if not (out/'applied_bank/result.txt').is_file():raise RuntimeError('No successful applied bank evidence')
with AFG1022() as d:
 try:
  before=d.output_on(1,waveform='sine',hz=100000,vpp=.175,offset_v=0,load='HIGHZ');time.sleep(2)
  reply=run(vr,ltx,out/'live_validation','read');after=d.settings(1)
  if before!=after:raise RuntimeError('Source changed during live validation')
  found=re.search(r' result \{([^}]+)\}',reply)
  if not found:raise RuntimeError('Missing live result')
  words=found.group(1).split();live={words[i]:int(words[i+1]) for i in range(0,len(words),2)}
  ref={'vpp_uv':175000,'rms_uv':175000/(2*math.sqrt(2)),'peak_uv':87500}
  errors={k:live[k]-v for k,v in ref.items()}
  record=dict(reference=ref,readback=live,errors_uv=errors,source_before=before,source_after=after)
  (out/'live_validation.json').write_text(json.dumps(record,indent=2));print('LIVE',json.dumps(record),flush=True)
  if live['valid']!=1 or any(abs(x)>5000 for x in errors.values()):raise RuntimeError('Live validation failed: no save')
 finally:
  d.output_off(1);d.output_off(2);print('OUTPUTS_OFF',d.settings(1)['output'],d.settings(2)['output'],flush=True)
print('SAVE',run(vr,ltx,out/'save','store_save'),flush=True)
print('EXPORT',run(vr,ltx,out/'export','store_export'),flush=True)
