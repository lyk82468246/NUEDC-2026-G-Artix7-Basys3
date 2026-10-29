param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference='Stop'
$rcRoot=Split-Path -Parent $PSScriptRoot
$rcRun=Join-Path $rcRoot 'test_results\runtime_calibration_sim'
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:XILINX_VIVADO=$VivadoRoot
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
New-Item -ItemType Directory -Path $rcRun -Force | Out-Null
Push-Location -LiteralPath $rcRun
try {
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib (Join-Path $rcRoot 'sources\rtl\Runtime_Calibration.v') (Join-Path $rcRoot 'sim\tb_runtime_calibration.sv')
    if($LASTEXITCODE -ne 0){throw 'Runtime calibration compile failed'}
    foreach($rcTop in @('tb_runtime_calibration','tb_runtime_calibration_boot','tb_runtime_calibration_zero_boot')) {
        & "$VivadoRoot\bin\xelab.bat" "xil_defaultlib.$rcTop" -s $rcTop
        if($LASTEXITCODE -ne 0){throw "Runtime calibration elaboration failed: $rcTop"}
        & "$VivadoRoot\bin\xsim.bat" $rcTop -runall -log "$rcTop.log"
        $rcText=Get-Content "$rcTop.log" -Raw
        if($LASTEXITCODE -ne 0 -or $rcText -match 'Fatal:|ERROR:|FAIL:' -or $rcText -notmatch 'PASS:'){throw "Runtime calibration self-check failed: $rcTop"}
    }
} finally {Pop-Location}
