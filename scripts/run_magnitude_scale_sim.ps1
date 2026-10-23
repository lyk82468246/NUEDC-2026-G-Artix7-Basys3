param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference='Stop'
$scaleRoot=Split-Path -Parent $PSScriptRoot
$scaleRun=Join-Path $scaleRoot 'test_results\magnitude_scale_sim'
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:XILINX_VIVADO=$VivadoRoot
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
New-Item -ItemType Directory -Path $scaleRun -Force | Out-Null
Push-Location -LiteralPath $scaleRun
try {
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib (Join-Path $scaleRoot 'sources\ip\cordic_translate_mag\cordic_translate_mag_sim_netlist.v') (Join-Path $scaleRoot 'sim\tb_cordic_magnitude_scale.sv')
    if($LASTEXITCODE -ne 0){throw 'CORDIC netlist compile failed'}
    & "$VivadoRoot\bin\xelab.bat" -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip xil_defaultlib.tb_cordic_magnitude_scale xil_defaultlib.glbl -s magnitude_scale
    if($LASTEXITCODE -ne 0){throw 'CORDIC scale elaboration failed'}
    & "$VivadoRoot\bin\xsim.bat" magnitude_scale -runall -log magnitude_scale.log
    $scaleText=Get-Content magnitude_scale.log -Raw
    if($LASTEXITCODE -ne 0 -or $scaleText -match 'Fatal:|ERROR:|FAIL:' -or $scaleText -notmatch 'PASS:'){throw 'CORDIC scale assertions failed'}
} finally {Pop-Location}
