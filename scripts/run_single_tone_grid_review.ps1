param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference='Stop'
$gridRoot=Split-Path -Parent $PSScriptRoot
$gridRun=Join-Path $gridRoot 'test_results\single_tone_grid_review_20261106'
& "$gridRoot\.venv-hds\Scripts\python.exe" -E "$gridRoot\scripts\contest\review_single_tone_grid.py" --output-dir $gridRun
if($LASTEXITCODE -ne 0){throw 'Grid fixture generation failed'}
$env:XILINX_VIVADO=$VivadoRoot
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
Push-Location -LiteralPath $gridRun
try {
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib "$gridRoot\sources\rtl\Component_Analyzer.v" "$gridRoot\sim\tb_single_tone_grid_review.sv"
    if($LASTEXITCODE -ne 0){throw 'Grid compile failed'}
    & "$VivadoRoot\bin\xelab.bat" xil_defaultlib.tb_single_tone_grid_review -s single_tone_grid_review
    if($LASTEXITCODE -ne 0){throw 'Grid elaboration failed'}
    & "$VivadoRoot\bin\xsim.bat" single_tone_grid_review -runall -log single_tone_grid_review.log
    $gridText=Get-Content single_tone_grid_review.log -Raw
    if($LASTEXITCODE -ne 0 -or $gridText -match 'Fatal:|ERROR:|FAIL:' -or $gridText -notmatch 'PASS: 246'){
        throw 'Grid assertions failed'
    }
} finally {Pop-Location}
