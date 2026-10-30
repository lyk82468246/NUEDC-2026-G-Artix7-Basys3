param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference='Stop'
$prepRoot=Split-Path -Parent $PSScriptRoot
$prepRun=Join-Path $prepRoot 'test_results\calibration_store_sim'
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:XILINX_VIVADO=$VivadoRoot
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
New-Item -ItemType Directory -Path $prepRun -Force | Out-Null
& "$prepRoot\.venv-hds\Scripts\python.exe" "$prepRoot\scripts\generate_flash_calibration_vectors.py" --output-dir $prepRun
if($LASTEXITCODE -ne 0){throw 'Fixture generation failed'}
Push-Location -LiteralPath $prepRun
try {
    $prepFiles=@('Flash_SPI_Byte.v','Flash_Command_Engine.v','Calibration_Record_Encoder.v','Calibration_Record_Decoder.v','Calibration_Record_Select.v','Calibration_Store.v','Runtime_Calibration.v') |
        ForEach-Object {Join-Path "$prepRoot\sources\rtl" $_}
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib @prepFiles "$prepRoot\sim\tb_calibration_store.sv" "$prepRoot\sim\tb_flash_store_contracts.sv"
    if($LASTEXITCODE -ne 0){throw 'Calibration persistence compile failed'}
    foreach($prepTop in @('tb_calibration_store','tb_flash_command_guard','tb_calibration_encoder','tb_runtime_restore_atomic')){
        & "$VivadoRoot\bin\xelab.bat" "xil_defaultlib.$prepTop" -s $prepTop
        if($LASTEXITCODE -ne 0){throw "Calibration persistence elaboration failed: $prepTop"}
        & "$VivadoRoot\bin\xsim.bat" $prepTop -runall -log "$prepTop.log"
        $prepText=Get-Content "$prepTop.log" -Raw
        if($LASTEXITCODE -ne 0 -or $prepText -match 'Fatal:|ERROR:|FAIL:' -or $prepText -notmatch 'PASS:'){
            throw "Calibration persistence assertions failed: $prepTop"
        }
    }
    $allRTL=Get-ChildItem -LiteralPath "$prepRoot\sources\rtl" -Filter '*.v' | ForEach-Object {$_.FullName}
    $allStubs=Get-ChildItem -LiteralPath "$prepRoot\sources\ip" -Recurse -Filter '*_stub.v' | Where-Object {$_.Name -notin @('ila_system_stub.v','vio_flash_store_stub.v')} | ForEach-Object {$_.FullName}
    & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib @allRTL @allStubs "$prepRoot\sim\ila_system_debug_contract.sv" "$prepRoot\sim\tb_flash_persistent_top_contract.sv" "$VivadoRoot\data\verilog\src\glbl.v"
    if($LASTEXITCODE -ne 0){throw 'Persistent top compile failed'}
    & "$VivadoRoot\bin\xelab.bat" -L unisims_ver -L unimacro_ver -L secureip xil_defaultlib.tb_flash_persistent_top_contract xil_defaultlib.glbl -s flash_persistent_top_contract
    if($LASTEXITCODE -ne 0){throw 'Persistent top elaboration failed'}
    & "$VivadoRoot\bin\xsim.bat" flash_persistent_top_contract -runall -log flash_persistent_top_contract.log
    $topText=Get-Content flash_persistent_top_contract.log -Raw
    if($LASTEXITCODE -ne 0 -or $topText -match 'Fatal:|ERROR:|FAIL:' -or $topText -notmatch 'PASS:'){throw 'Persistent top assertions failed'}
} finally {Pop-Location}
