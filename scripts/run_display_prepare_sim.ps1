param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference='Stop'
$prepRoot=Split-Path -Parent $PSScriptRoot
$prepRun=Join-Path $prepRoot 'test_results\display_prepare_sim'
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:XILINX_VIVADO=$VivadoRoot
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
New-Item -ItemType Directory -Path $prepRun -Force | Out-Null
Push-Location -LiteralPath $prepRun
try {
    $prepFiles=@('BIN2BCD.v','Display_Unsigned_Divider.v','Display_Frame_Calibrator.v','Display_Sine_ROM.v','Display_Fundamental_Aligner.v','Display_Wave_Renderer.v','Display_Spectrum_Renderer.v','Display_mV_Formatter.v') |
        ForEach-Object {Join-Path "$prepRoot\sources\rtl" $_}
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib @prepFiles "$prepRoot\sim\tb_display_prepare.sv"
    if($LASTEXITCODE -ne 0){throw 'Display preparation compile failed'}
    foreach($prepTop in @('tb_display_prepare','tb_display_prepare_compact','tb_display_prepare_full_y')){
        & "$VivadoRoot\bin\xelab.bat" "xil_defaultlib.$prepTop" -s $prepTop
        if($LASTEXITCODE -ne 0){throw "Display preparation elaboration failed: $prepTop"}
        & "$VivadoRoot\bin\xsim.bat" $prepTop -runall -log "$prepTop.log"
        $prepText=Get-Content "$prepTop.log" -Raw
        if($LASTEXITCODE -ne 0 -or $prepText -match 'Fatal:|ERROR:|FAIL:' -or $prepText -notmatch 'PASS:'){
            throw "Display preparation assertions failed: $prepTop"
        }
    }
} finally {Pop-Location}
