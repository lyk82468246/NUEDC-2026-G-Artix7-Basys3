"""Exclusive JTAG calibration session; NEVER synthesizes, resets or programs.

Do not run concurrently with lab service/GUI JTAG operations. Shares the ILA
process lock. apply is never retried automatically after timeout/failure.
"""
import argparse
import os
from pathlib import Path
import subprocess
import threading
import time
from hds242s import ROOT, _terminate_process
from resource_lock import ResourceLock
from vivado_paths import aliased, workspace_alias


def run(vivado, ltx, directory, action, gains=None, enabled=1):
    if action not in ('inspect','read','apply'):
        raise ValueError('Unsupported action')
    if action == 'apply' and (not gains or len(gains)!=3 or any(type(x)!=int or not 0<=x<=0xffffffff for x in gains)):
        raise ValueError('Three uint32 gains required')
    if enabled not in (0,1):raise ValueError('enabled must be 0/1')
    vivado,ltx=Path(vivado).resolve(),Path(ltx).resolve()
    if not vivado.is_file() or not ltx.is_file():raise ValueError('Missing Vivado/LTX')
    directory=Path(directory).resolve()
    directory.mkdir(parents=True,exist_ok=False)
    env=os.environ.copy()
    root=vivado.parents[1]
    env.update(XILINX_VIVADO=str(root),PROCESSOR_ARCHITECTURE='AMD64',XILINX_LOCAL_USER_DATA='NO')
    env['PATH']=os.pathsep.join([str(root/'lib/win64.o'),str(root/'bin'),str(root/'bin/unwrapped/win64.o'),env.get('PATH','')])
    with ResourceLock(ROOT/'.lab_locks/fpga_ila.lock'), workspace_alias(ROOT) as alias, (directory/'vivado.txt').open('wb') as log:
        args=[str(vivado),'-mode','batch','-nolog','-nojournal','-source',
              aliased(ROOT/'scripts/runtime_calibration_hw.tcl',ROOT,alias),'-tclargs',
              aliased(directory/'result.txt',ROOT,alias),aliased(ltx,ROOT,alias),action]
        if action=='apply':args.extend([str(x) for x in gains]+[str(enabled)])
        process=subprocess.Popen(args,cwd=aliased(directory,ROOT,alias),env=env,stdout=log,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+90
        try:
            while process.poll() is None:
                if time.monotonic()>deadline:raise TimeoutError('VIO session deadline; inspect hardware state before any write retry')
                threading.Event().wait(.1)
        finally:
            _terminate_process(process)
        if process.returncode or not (directory/'result.txt').is_file():
            raise RuntimeError(f'VIO operation failed; see {directory / "vivado.txt"}; no automatic retry')
    return (directory/'result.txt').read_text(encoding='utf-8')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['inspect','read','apply'])
    p.add_argument('--vivado',default='C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat')
    p.add_argument('--ltx',required=True,type=Path)
    p.add_argument('--directory',required=True,type=Path)
    p.add_argument('--gains',type=int,nargs=3)
    p.add_argument('--enabled',type=int,choices=[0,1],default=1)
    a=p.parse_args()
    print(run(a.vivado,a.ltx,a.directory,a.action,a.gains,a.enabled))


if __name__=='__main__':main()
