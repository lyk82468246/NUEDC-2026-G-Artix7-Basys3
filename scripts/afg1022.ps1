# Forward arguments; use the same environment as the other instruments.
$pythonPath = Join-Path $PSScriptRoot '../.venv-hds/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $pythonPath)) {
    $pythonPath = (Get-Command python -ErrorAction Stop).Source
}
& $pythonPath (Join-Path $PSScriptRoot 'instruments/afg1022.py') @args
exit $LASTEXITCODE
