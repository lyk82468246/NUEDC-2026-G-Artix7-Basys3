param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference='Stop'
$romRoot=Split-Path -Parent $PSScriptRoot
$romRun=Join-Path $romRoot 'test_results\flattop_rom_contract_review'
New-Item -ItemType Directory -Force -Path $romRun | Out-Null
@'
import sys
from pathlib import Path
root,output=map(Path,sys.argv[1:])
s=(root/'sources/coeffs/flat_top_window_8192.coe').read_text()
v=[int(x.strip()) for x in s.split('memory_initialization_vector=',1)[1].split(';')[0].split(',')]
assert len(v)==8192
(output/'expected.mem').write_text(''.join(f'{x&65535:04x}\n' for x in v))
'@ | & "$romRoot\.venv-hds\Scripts\python.exe" -E - $romRoot $romRun
if($LASTEXITCODE -ne 0){throw 'ROM reference preparation failed'}
Copy-Item -LiteralPath "$romRoot\sources\ip\flat_top_window_rom\flat_top_window_rom.mif" -Destination $romRun
$env:XILINX_VIVADO=$VivadoRoot
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
Push-Location -LiteralPath $romRun
try {
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib `
        "$romRoot\sources\ip\flat_top_window_rom\flat_top_window_rom_sim_netlist.v" `
        "$romRoot\sources\rtl\FlatTop_Window_ROM.v" "$romRoot\sim\tb_flattop_rom_latency_review.sv"
    if($LASTEXITCODE -ne 0){throw 'ROM review compile failed'}
    foreach($romTop in @('tb_flattop_rom_latency_review','tb_flattop_rom_double_enable_review')){
        & "$VivadoRoot\bin\xelab.bat" -L unisims_ver -L unimacro_ver -L secureip "xil_defaultlib.$romTop" xil_defaultlib.glbl -s $romTop
        if($LASTEXITCODE -ne 0){throw 'ROM review elaboration failed'}
        & "$VivadoRoot\bin\xsim.bat" $romTop -runall -log "$romTop.log"
        $romText=Get-Content "$romTop.log" -Raw
        if($LASTEXITCODE -ne 0 -or $romText -match 'Fatal:|ERROR:|FAIL:' -or $romText -notmatch 'PASS: actual ROM'){
            throw 'ROM review assertions failed'
        }
    }
} finally {Pop-Location}
