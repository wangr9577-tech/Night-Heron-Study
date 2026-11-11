param([switch]$IncludeOCR)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath (Split-Path $PSScriptRoot -Parent)
$env:PYTHONIOENCODING = 'utf-8'
if ($IncludeOCR) { $env:ZHUOZHI_TEST_OCR = 'true' }
& '.venv/Scripts/python.exe' -m pytest
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
