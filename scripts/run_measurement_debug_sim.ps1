param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference='Stop'
$debugRoot=Split-Path -Parent $PSScriptRoot
$debugRun=Join-Path $debugRoot 'test_results\measurement_debug_sim'
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:XILINX_VIVADO=$VivadoRoot
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
New-Item -ItemType Directory -Path $debugRun -Force | Out-Null
Push-Location -LiteralPath $debugRun
try {
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib `
      "$debugRoot\sources\rtl\Measurement_Debug_Snapshot.v" `
      "$debugRoot\sources\rtl\Runtime_Calibration.v" "$debugRoot\sim\tb_measurement_debug_snapshot.sv"
    if($LASTEXITCODE -ne 0){throw 'Debug snapshot compile failed'}
    & "$VivadoRoot\bin\xelab.bat" xil_defaultlib.tb_measurement_debug_snapshot -s measurement_debug
    if($LASTEXITCODE -ne 0){throw 'Debug snapshot elaboration failed'}
    & "$VivadoRoot\bin\xsim.bat" measurement_debug -runall -log measurement_debug.log
    $debugText=Get-Content measurement_debug.log -Raw
    if($LASTEXITCODE -ne 0 -or $debugText -match 'Fatal:|ERROR:|FAIL:' -or $debugText -notmatch 'PASS:'){
        throw 'Debug snapshot assertions failed'
    }
    # Separate top connection check; real generated IP products remain untouched.
    $debugRTL=Get-ChildItem -LiteralPath "$debugRoot\sources\rtl" -Filter '*.v' | ForEach-Object {$_.FullName}
    $debugStubs=Get-ChildItem -LiteralPath "$debugRoot\sources\ip" -Recurse -Filter '*_stub.v' |
        Where-Object {$_.Name -ne 'ila_system_stub.v'} | ForEach-Object {$_.FullName}
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib @debugRTL @debugStubs `
      "$debugRoot\sim\ila_system_debug_contract.sv" "$debugRoot\sim\tb_debug_top_contract.sv" `
      "$VivadoRoot\data\verilog\src\glbl.v"
    if($LASTEXITCODE -ne 0){throw 'Top contract compile failed'}
    & "$VivadoRoot\bin\xelab.bat" -L unisims_ver -L unimacro_ver -L secureip `
      xil_defaultlib.tb_debug_top_contract xil_defaultlib.glbl -s debug_top_contract
    if($LASTEXITCODE -ne 0){throw 'Top contract elaboration failed'}
    & "$VivadoRoot\bin\xsim.bat" debug_top_contract -runall -log debug_top_contract.log
    $debugText=Get-Content debug_top_contract.log -Raw
    if($LASTEXITCODE -ne 0 -or $debugText -match 'Fatal:|ERROR:|FAIL:' -or $debugText -notmatch 'PASS:'){
        throw 'Top contract self-check failed'
    }
} finally {Pop-Location}
