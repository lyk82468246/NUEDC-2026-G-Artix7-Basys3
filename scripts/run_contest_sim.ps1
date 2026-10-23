param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference='Stop'
$contestRoot=Split-Path -Parent $PSScriptRoot
$contestRun=Join-Path $contestRoot 'test_results\contest_sim'
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:XILINX_VIVADO=$VivadoRoot
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
New-Item -ItemType Directory -Path $contestRun -Force | Out-Null
$contestPython=Join-Path $contestRoot '.venv-hds\Scripts\python.exe'
if(-not (Test-Path -LiteralPath $contestPython)){throw 'Missing .venv-hds Python; create the project environment before running contest simulations.'}
& $contestPython (Join-Path $PSScriptRoot 'contest\reference_model.py') --output-dir (Join-Path $contestRoot 'test_results\contest_reference')
if($LASTEXITCODE -ne 0){throw 'Reference fixture generation failed'}
Push-Location -LiteralPath $contestRun
try {
    $contestSources=@('Switch_Filter.v','Run_Controller.v','BIN2BCD.v','SevenSeg_Scan.v','Board_Status_Display.v','Button_Debounce.v','AFE_Capture.v','Component_Analyzer.v','Measurement_Calibrator.v','HMI_UART_Ctrl.v') | ForEach-Object { Join-Path "$contestRoot\sources\rtl" $_ }
    $contestTests=@('tb_run_controller','tb_board_panel','tb_afe_frame_ownership','tb_afe_small_signal','tb_component_analyzer','tb_measurement_calibrator','tb_hmi_signal_valid','tb_hmi_uart')
    $contestTestFiles=$contestTests | ForEach-Object { Join-Path "$contestRoot\sim" "$_.sv" }
    # Extra top is defined in tb_hmi_signal_valid.sv; no duplicate source file.
    $contestTests += 'tb_hmi_signal_valid_direct'
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib @contestSources @contestTestFiles
    if($LASTEXITCODE -ne 0){throw 'Contest compile failed'}
    foreach($contestTest in $contestTests){
        & "$VivadoRoot\bin\xelab.bat" -debug typical -s $contestTest "xil_defaultlib.$contestTest"
        if($LASTEXITCODE -ne 0){throw "Elaboration failed: $contestTest"}
        & "$VivadoRoot\bin\xsim.bat" $contestTest -runall -log "$contestTest.log"
        $contestText=Get-Content -LiteralPath "$contestTest.log" -Raw
        if($LASTEXITCODE -ne 0 -or $contestText -match 'Fatal:|ERROR:|FAIL:' -or $contestText -notmatch 'PASS:') {throw "Self-check failed: $contestTest"}
    }
    Write-Host 'PASS: all contest control/AFE simulations'
} finally { Pop-Location }
