param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference='Stop'
$hmiRoot=Split-Path -Parent $PSScriptRoot
$hmiRun=Join-Path $hmiRoot 'test_results\display_hmi_sim'
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:XILINX_VIVADO=$VivadoRoot
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
New-Item -ItemType Directory -Path $hmiRun -Force | Out-Null
Push-Location -LiteralPath $hmiRun
try {
    $hmiFiles=@('BIN2BCD','HMI_UART_Ctrl','Display_Unsigned_Divider','Display_Frame_Calibrator',
        'Display_Sine_ROM','Display_Fundamental_Aligner','Display_Interpolation_ROM','Display_Bandlimited_Interpolator','Display_Wave_Renderer','Display_Spectrum_Renderer','Display_mV_Formatter','Display_UART_Command','Display_HMI') |
        ForEach-Object {Join-Path "$hmiRoot\sources\rtl" "$_.v"}
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib @hmiFiles "$hmiRoot\sim\tb_display_hmi.sv" "$hmiRoot\sim\tb_display_aligned_hmi.sv"
    if($LASTEXITCODE -ne 0){throw 'Display HMI compile failed'}
    foreach($hmiTop in @('tb_display_hmi','tb_display_hmi_full','tb_display_hmi_inverted','tb_display_hmi_no_guard','tb_display_aligned_hmi','tb_display_hmi_forward')) {
        & "$VivadoRoot\bin\xelab.bat" "xil_defaultlib.$hmiTop" -s $hmiTop
        if($LASTEXITCODE -ne 0){throw "Display HMI elaboration failed: $hmiTop"}
        & "$VivadoRoot\bin\xsim.bat" $hmiTop -runall -log "$hmiTop.log"
        $hmiText=Get-Content "$hmiTop.log" -Raw
        if($LASTEXITCODE -ne 0 -or $hmiText -match 'Fatal:|ERROR:|FAIL:' -or $hmiText -notmatch 'PASS:'){
            throw "Display HMI assertions failed: $hmiTop"
        }
    }
} finally {Pop-Location}
