param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado',[switch]$CheckLegacy)
$ErrorActionPreference='Stop'
$winRoot=Split-Path -Parent $PSScriptRoot
$winRun=Join-Path $winRoot 'test_results\fft_window_backpressure_sim'
New-Item -ItemType Directory -Force -Path $winRun | Out-Null
Copy-Item -LiteralPath "$winRoot\sources\ip\flat_top_window_rom\flat_top_window_rom.mif" -Destination $winRun
$env:XILINX_VIVADO=$VivadoRoot
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
Push-Location -LiteralPath $winRun
try {
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib `
        "$winRoot\sources\ip\flat_top_window_rom\flat_top_window_rom_sim_netlist.v" `
        "$winRoot\sources\rtl\FlatTop_Window_ROM.v" "$winRoot\sources\rtl\FFT_Processor.v" `
        "$winRoot\sim\fft_window_input_models.sv" "$winRoot\sim\tb_fft_window_backpressure.sv"
    if($LASTEXITCODE -ne 0){throw 'Window input compile failed'}
    & "$VivadoRoot\bin\xelab.bat" -L unisims_ver -L unimacro_ver -L secureip xil_defaultlib.tb_fft_window_backpressure xil_defaultlib.glbl -s fft_window_backpressure
    if($LASTEXITCODE -ne 0){throw 'Window input elaboration failed'}
    & "$VivadoRoot\bin\xsim.bat" fft_window_backpressure -runall -log fft_window_backpressure.log
    $winText=Get-Content fft_window_backpressure.log -Raw
    if($LASTEXITCODE -ne 0 -or $winText -match 'Fatal:|ERROR:|FAIL:' -or $winText -notmatch 'golden checks=24576'){
        throw 'Window input assertions failed'
    }
    if($CheckLegacy){
        # Negative control is isolated/renamed; it never replaces production RTL.
        $oldSource=git -C $winRoot show '63c1688:sources/rtl/FFT_Processor.v'
        if($LASTEXITCODE -ne 0){throw 'Legacy source unavailable'}
        $winUtf8=[System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $winRun 'legacy_fft.v'),
            ($oldSource -join "`n").Replace('module FFT_Processor #(','module FFT_Processor_legacy #('),$winUtf8)
        $oldBench=(Get-Content "$winRoot\sim\tb_fft_window_backpressure.sv" -Raw).
            Replace('module tb_fft_window_backpressure;','module tb_fft_window_legacy;').
            Replace('FFT_Processor dut(','FFT_Processor_legacy dut(')
        [System.IO.File]::WriteAllText((Join-Path $winRun 'legacy_tb.sv'),$oldBench,$winUtf8)
        & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib legacy_fft.v legacy_tb.sv
        if($LASTEXITCODE -ne 0){throw 'Legacy negative control compile failed'}
        & "$VivadoRoot\bin\xelab.bat" -L unisims_ver -L unimacro_ver -L secureip xil_defaultlib.tb_fft_window_legacy xil_defaultlib.glbl -s fft_window_legacy
        if($LASTEXITCODE -ne 0){throw 'Legacy negative control elaboration failed'}
        & "$VivadoRoot\bin\xsim.bat" fft_window_legacy -runall -log fft_window_legacy.log
        $oldText=Get-Content fft_window_legacy.log -Raw
        if($oldText -notmatch 'Fatal: Window golden mismatch') {throw 'Legacy did not fail the same golden test'}
        Write-Host 'PASS: legacy negative control failed exactly at the window golden assertion'
    }
} finally {Pop-Location}
