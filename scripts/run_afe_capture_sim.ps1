param([ValidatePattern('^[a-z0-9_]+$')][string]$Tag = 'fixed')
$ErrorActionPreference = 'Stop'
$afeProjectRoot = Split-Path -Parent $PSScriptRoot
$afeVivadoRoot = 'C:\AMDDesignTools\2025.2\Vivado'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:XILINX_LOCAL_USER_DATA = 'NO'
$env:XILINX_VIVADO = $afeVivadoRoot
$env:PATH = "$afeVivadoRoot\lib\win64.o;$afeVivadoRoot\bin;$afeVivadoRoot\bin\unwrapped\win64.o;$env:PATH"
$afeRunDirectory = Join-Path $afeProjectRoot "test_results\afe_capture_$Tag"
New-Item -ItemType Directory -Path $afeRunDirectory -Force | Out-Null
Push-Location -LiteralPath $afeRunDirectory
try {
    & "$afeVivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib "$afeProjectRoot\sources\rtl\AFE_Capture.v" "$afeProjectRoot\sim\tb_afe_small_signal.sv"
    if ($LASTEXITCODE -ne 0) { throw 'AFE compile failed' }
    & "$afeVivadoRoot\bin\xelab.bat" -debug typical -s tb_afe_small_signal xil_defaultlib.tb_afe_small_signal
    if ($LASTEXITCODE -ne 0) { throw 'AFE elaborate failed' }
    & "$afeVivadoRoot\bin\xsim.bat" tb_afe_small_signal -runall
    $afeLog = Get-Content -LiteralPath 'xsim.log' -Raw
    if ($LASTEXITCODE -ne 0 -or $afeLog -match 'Fatal:|ERROR:|FAIL:' -or $afeLog -notmatch 'PASS:') {
        throw "AFE self-check failed; see $afeRunDirectory\xsim.log"
    }
} finally { Pop-Location }
