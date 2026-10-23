# Forward all arguments verbatim; works from any current directory.
$pythonPath = Join-Path $PSScriptRoot '../.venv-hds/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $pythonPath)) {
    $pythonPath = (Get-Command python -ErrorAction Stop).Source
}
& $pythonPath (Join-Path $PSScriptRoot 'instruments/utg932.py') @args
exit $LASTEXITCODE
