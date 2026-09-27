[CmdletBinding()]
param(
    [string]$VivadoBin = 'C:\AMDDesignTools\2025.2\Vivado\bin'
)

#==============================================================================
# run_behavioral_sim.ps1
#------------------------------------------------------------------------------
# Windows/XSim regression for the four self-checking testbenches in sim/.
# The script deliberately checks xsim.log for Fatal/ERROR text because the
# Vivado 2025.2 xsim wrapper can return exit code 0 even after a SystemVerilog
# $fatal terminates the simulation.
#==============================================================================

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot

$VivadoBin = (Resolve-Path -LiteralPath $VivadoBin).Path
$vivadoRoot = Split-Path -Parent $VivadoBin
$vivadoLib = Join-Path $vivadoRoot 'lib\win64.o'
$vivadoUnwrapped = Join-Path $VivadoBin 'unwrapped\win64.o'
if (-not (Test-Path -LiteralPath $vivadoLib)) {
    throw "Vivado runtime library directory not found: $vivadoLib"
}

$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:XILINX_LOCAL_USER_DATA = 'NO'
$env:XILINX_VIVADO = $vivadoRoot
# Vivado's .bat launchers normally add these directories themselves.  A
# regular PowerShell session does not necessarily have that initialized PATH;
# add the runtime DLL directory explicitly so xvlog/xelab/xsim are repeatable.
$env:PATH = "$vivadoLib;$VivadoBin;$vivadoUnwrapped;$env:PATH"

function Invoke-VivadoTool {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $false)][string[]]$Arguments = @()
    )

    $toolPath = Join-Path $VivadoBin ($Tool + '.bat')
    if (-not (Test-Path -LiteralPath $toolPath)) {
        throw "Vivado tool not found: $toolPath"
    }

    & $toolPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Tool returned exit code $LASTEXITCODE"
    }
}

function Invoke-XSimRegression {
    param(
        [Parameter(Mandatory = $true)][string]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Write-Host "==> $Description"
    Invoke-VivadoTool 'xsim' @($Snapshot, '-runall')

    $xsimLogPath = Join-Path $projectRoot 'xsim.log'
    if (-not (Test-Path -LiteralPath $xsimLogPath)) {
        throw "xsim.log was not generated for $Snapshot"
    }
    $xsimLog = Get-Content -LiteralPath $xsimLogPath -Raw
    if ($xsimLog -match '(?m)Fatal:|(?m)ERROR:|FAIL:') {
        throw "Simulation assertions failed for $Snapshot. See xsim.log."
    }
    if ($xsimLog -notmatch 'PASS:') {
        throw "Simulation did not print a PASS marker for $Snapshot."
    }
    Write-Host "PASS: $Snapshot"
}

# Time-domain statistics plus the generated CORDIC square-root behavior model.
Invoke-VivadoTool 'xvlog' @(
    '-sv', '-work', 'xil_defaultlib',
    'sources\ip\cordic_sqrt_rms\cordic_sqrt_rms_sim_netlist.v',
    'sources\rtl\Time_Domain_Calc.v',
    'sim\tb_time_domain_calc.sv'
)
Invoke-VivadoTool 'xelab' @(
    '-debug', 'typical', '-L', 'xil_defaultlib', '-L', 'unisims_ver',
    '-L', 'unimacro_ver', '-L', 'secureip',
    'xil_defaultlib.tb_time_domain_calc', 'xil_defaultlib.glbl',
    '-s', 'sim_time_domain'
)
Invoke-XSimRegression 'sim_time_domain' 'Time_Domain_Calc'

# Flat-top ROM, 8192-point XFFT, CORDIC magnitude and AXI4-Stream assertions.
Invoke-VivadoTool 'xvlog' @(
    '-sv', '-work', 'xil_defaultlib',
    'sources\ip\xfft_8192\xfft_8192_sim_netlist.v',
    'sources\ip\flat_top_window_rom\flat_top_window_rom_sim_netlist.v',
    'sources\ip\cordic_translate_mag\cordic_translate_mag_sim_netlist.v',
    'sources\rtl\FlatTop_Window_ROM.v',
    'sources\rtl\FFT_Processor.v',
    'sim\tb_fft_processor.sv'
)
Invoke-VivadoTool 'xelab' @(
    '-debug', 'typical', '-L', 'xil_defaultlib', '-L', 'unisims_ver',
    '-L', 'unimacro_ver', '-L', 'secureip',
    'xil_defaultlib.tb_fft_processor', 'xil_defaultlib.glbl',
    '-s', 'sim_fft_processor'
)
Invoke-XSimRegression 'sim_fft_processor' 'FFT_Processor'

# Peak scan range, maximum selection, frequency conversion and magnitude scale.
Invoke-VivadoTool 'xvlog' @(
    '-sv', '-work', 'xil_defaultlib',
    'sources\rtl\Peak_Search.v',
    'sim\tb_peak_search.sv'
)
Invoke-VivadoTool 'xelab' @(
    '-debug', 'typical', '-L', 'xil_defaultlib',
    'xil_defaultlib.tb_peak_search', '-s', 'sim_peak_search'
)
Invoke-XSimRegression 'sim_peak_search' 'Peak_Search'

# Double-Dabble, scaled-clock 115200-baud UART decoding and HMI command stream.
Invoke-VivadoTool 'xvlog' @(
    '-sv', '-work', 'xil_defaultlib',
    'sources\rtl\BIN2BCD.v',
    'sources\rtl\HMI_UART_Ctrl.v',
    'sim\tb_hmi_uart.sv'
)
Invoke-VivadoTool 'xelab' @(
    '-debug', 'typical', '-L', 'xil_defaultlib',
    'xil_defaultlib.tb_hmi_uart', '-s', 'sim_hmi_uart'
)
Invoke-XSimRegression 'sim_hmi_uart' 'HMI_UART_Ctrl/BIN2BCD/UART_Tx'

Write-Host 'All behavioral simulations passed.'
