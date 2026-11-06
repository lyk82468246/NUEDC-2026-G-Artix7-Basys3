param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference='Stop'
$fftRoot=Split-Path -Parent $PSScriptRoot
$fftRun=Join-Path $fftRoot 'test_results\fft_rom_alignment_sim'
New-Item -ItemType Directory -Force -Path "$fftRun\sources\coeffs" | Out-Null
Copy-Item -LiteralPath "$fftRoot\sources\coeffs\flat_top_window_8192.coe" -Destination "$fftRun\sources\coeffs"
Copy-Item -LiteralPath "$fftRoot\sources\ip\flat_top_window_rom\flat_top_window_rom.mif" -Destination $fftRun
$env:XILINX_VIVADO=$VivadoRoot
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
Push-Location -LiteralPath $fftRun
try {
    $fftFiles=@('xfft_8192','flat_top_window_rom','cordic_translate_mag') |
        ForEach-Object {"$fftRoot\sources\ip\$_\${_}_sim_netlist.v"}
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib @fftFiles `
        "$fftRoot\sources\rtl\FlatTop_Window_ROM.v" "$fftRoot\sources\rtl\FFT_Processor.v" "$fftRoot\sim\tb_fft_processor.sv"
    if($LASTEXITCODE -ne 0){throw 'FFT real-IP compile failed'}
    & "$VivadoRoot\bin\xelab.bat" -L unisims_ver -L unimacro_ver -L secureip xil_defaultlib.tb_fft_processor xil_defaultlib.glbl -s fft_rom_alignment
    if($LASTEXITCODE -ne 0){throw 'FFT real-IP elaboration failed'}
    & "$VivadoRoot\bin\xsim.bat" fft_rom_alignment -runall -log fft_rom_alignment.log
    $fftText=Get-Content fft_rom_alignment.log -Raw
    if($LASTEXITCODE -ne 0 -or $fftText -match 'Fatal:|ERROR:|FAIL:' -or $fftText -notmatch '24576 golden window pairs'){
        throw 'FFT alignment/protocol assertions failed'
    }
} finally {Pop-Location}
