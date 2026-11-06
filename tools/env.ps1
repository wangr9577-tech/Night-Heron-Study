# Optional local development environment. Dot-source this script from PowerShell.
# Configure FLUTTER_HOME and proxy variables externally when needed.
$ZHI_ROOT = Split-Path -Parent $PSScriptRoot
$ZHI_PY = Join-Path $ZHI_ROOT 'backend\.venv\Scripts\python.exe'
if ($env:FLUTTER_HOME) {
    $env:PATH = (Join-Path $env:FLUTTER_HOME 'bin') + [IO.Path]::PathSeparator + $env:PATH
}
Write-Host "Project: $ZHI_ROOT; Python: $ZHI_PY"
