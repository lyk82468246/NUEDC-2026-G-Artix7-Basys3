$pythonPath = Join-Path $PSScriptRoot '../.venv-hds/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $pythonPath)) {
    $pythonPath = (Get-Command python -ErrorAction Stop).Source
}
& $pythonPath (Join-Path $PSScriptRoot 'instruments/afg1022_gui.py') @args
exit $LASTEXITCODE
