@echo off
rem -----------------------------------------------------------------------------
rem Run the board-top synthesis/implementation check from Windows.
rem
rem Vivado 2025.2's Tcl file-normalizer in this environment folds the shell
rem folder "Documents" out of ordinary drive-letter paths.  A temporary SUBST
rem drive keeps the project path lossless.  The mapping is removed on exit.
rem -----------------------------------------------------------------------------
setlocal EnableExtensions EnableDelayedExpansion

set "PROJECT_ROOT=%~dp0.."
for %%I in ("%PROJECT_ROOT%") do set "PROJECT_ROOT=%%~fI"
set "VIVADO_BAT=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
if not "%VIVADO_BAT_OVERRIDE%"=="" set "VIVADO_BAT=%VIVADO_BAT_OVERRIDE%"

subst V: "%PROJECT_ROOT%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: cannot create temporary V: drive for "%PROJECT_ROOT%".
    exit /b 2
)

rem Vivado's loader requires this variable in the Codex Windows subprocess.
set "PROCESSOR_ARCHITECTURE=AMD64"
rem Use the direct project-mode flow.  It avoids the legacy runme.bat ->
rem cscript/vrs wrapper that can fail with "Loading your settings failed"
rem before Vivado has a chance to run synthesis.
call "%VIVADO_BAT%" -mode batch -nolog -nojournal -source V:\scripts\impl_check_board_top_direct.tcl -tclargs V:\G_FPGA.xpr
set "BUILD_STATUS=!errorlevel!"

subst V: /D >nul 2>&1
endlocal & exit /b %BUILD_STATUS%
