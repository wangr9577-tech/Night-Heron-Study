param([int]$Port = 8000, [switch]$Integrated)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath (Split-Path $PSScriptRoot -Parent)
if (!(Test-Path '.venv/Scripts/python.exe')) { uv sync --extra dev }
$env:ZHUOZHI_MODE = if ($Integrated) { 'integrated' } else { 'demo' }
$env:PYTHONIOENCODING = 'utf-8'
& '.venv/Scripts/python.exe' -m uvicorn backend.app:app --host 127.0.0.1 --port $Port
