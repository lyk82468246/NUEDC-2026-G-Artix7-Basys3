param([string]$VivadoRoot='C:\AMDDesignTools\2025.2\Vivado')
$ErrorActionPreference='Stop'
$flashRoot=Split-Path -Parent $PSScriptRoot
$flashRun=Join-Path $flashRoot 'test_results\flash_calibration_sim'
$env:PROCESSOR_ARCHITECTURE='AMD64'
$env:XILINX_LOCAL_USER_DATA='NO'
$env:XILINX_VIVADO=$VivadoRoot
$env:PATH="$VivadoRoot\lib\win64.o;$VivadoRoot\bin;$VivadoRoot\bin\unwrapped\win64.o;$env:PATH"
$env:PYTHONUTF8='1'
& "$flashRoot\.venv-hds\Scripts\python.exe" "$flashRoot\scripts\generate_flash_calibration_vectors.py" --output-dir $flashRun
if($LASTEXITCODE -ne 0){throw 'Flash fixture generation failed'}
Push-Location -LiteralPath $flashRun
try {
 $flashFiles=@('Flash_SPI_Byte','Flash_Read_Engine','Calibration_Record_Decoder','Calibration_Record_Select','Calibration_Flash_Restore') | ForEach-Object {Join-Path "$flashRoot\sources\rtl" "$_.v"}
 & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib @flashFiles "$flashRoot\sim\tb_flash_readonly.sv"
 if($LASTEXITCODE -ne 0){throw 'Flash compile failed'}
 foreach($flashTop in @('tb_flash_readonly','tb_flash_unknown','tb_flash_busy')) {
  & "$VivadoRoot\bin\xelab.bat" "xil_defaultlib.$flashTop" -s $flashTop
  if($LASTEXITCODE -ne 0){throw "Flash elaboration failed: $flashTop"}
  & "$VivadoRoot\bin\xsim.bat" $flashTop -runall -log "$flashTop.log"
  $flashText=Get-Content "$flashTop.log" -Raw
  if($LASTEXITCODE -ne 0 -or $flashText -match 'Fatal:|ERROR:|FAIL:' -or $flashText -notmatch 'PASS:'){throw "Flash assertions failed: $flashTop"}
 }
 # Elaboration contract for the actual optional board branch; no IP generation.
 $allRTL=Get-ChildItem -LiteralPath "$flashRoot\sources\rtl" -Filter '*.v' | ForEach-Object {$_.FullName}
 $allStubs=Get-ChildItem -LiteralPath "$flashRoot\sources\ip" -Recurse -Filter '*_stub.v' | Where-Object {$_.Name -notin @('ila_system_stub.v','vio_flash_calibration_stub.v')} | ForEach-Object {$_.FullName}
 & "$VivadoRoot\bin\xvlog.bat" -sv -work xil_defaultlib @allRTL @allStubs "$flashRoot\sim\ila_system_debug_contract.sv" "$flashRoot\sim\tb_flash_top_contract.sv" "$VivadoRoot\data\verilog\src\glbl.v"
 if($LASTEXITCODE -ne 0){throw 'Flash board contract compile failed'}
 & "$VivadoRoot\bin\xelab.bat" -L unisims_ver -L unimacro_ver -L secureip xil_defaultlib.tb_flash_top_contract xil_defaultlib.glbl -s flash_top_contract
 if($LASTEXITCODE -ne 0){throw 'Flash board contract elaboration failed'}
 & "$VivadoRoot\bin\xsim.bat" flash_top_contract -runall -log flash_top_contract.log
 $flashText=Get-Content flash_top_contract.log -Raw
 if($LASTEXITCODE -ne 0 -or $flashText -match 'Fatal:|ERROR:|FAIL:' -or $flashText -notmatch 'PASS:'){throw 'Flash board contract assertions failed'}
} finally {Pop-Location}
