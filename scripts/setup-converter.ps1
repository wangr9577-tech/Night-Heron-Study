# Extracts an official LibreOffice administrative image locally. No global Office install or registration.
$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$converterTarget = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '.tools\LibreOffice'))
if (!$converterTarget.StartsWith($projectRoot + [System.IO.Path]::DirectorySeparatorChar)) { throw 'Invalid target' }
if (Test-Path -LiteralPath (Join-Path $converterTarget 'program\soffice.com')) {
    & (Join-Path $converterTarget 'program\soffice.com') --version
    exit $LASTEXITCODE
}
$downloadDir = Join-Path $projectRoot 'tmp\libreoffice'
[void](New-Item -ItemType Directory -Path $downloadDir -Force)
[void](New-Item -ItemType Directory -Path (Split-Path $converterTarget -Parent) -Force)
$installerPath = Join-Path $downloadDir 'LibreOffice_26.2.6_Win_x86-64.msi'
$installerHash = 'F9877032FD908BEB9C0DDF06DF4AF5C2E85F419C42E14876C4CCE5AAE5FB2660'
if (!(Test-Path -LiteralPath $installerPath)) {
    Invoke-WebRequest -Uri 'https://download.documentfoundation.org/libreoffice/stable/26.2.6/win/x86_64/LibreOffice_26.2.6_Win_x86-64.msi' -OutFile $installerPath
}
if ((Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash -ne $installerHash) { throw 'Installer hash mismatch' }
$extractLog = Join-Path $downloadDir 'extract.log'
$extractProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/a',('"'+$installerPath+'"'),'/qn',('TARGETDIR="'+$converterTarget+'"'),'/l*v',('"'+$extractLog+'"')) -WindowStyle Hidden -Wait -PassThru
if ($extractProcess.ExitCode -ne 0) { throw ('Extraction failed: '+$extractProcess.ExitCode) }
& (Join-Path $converterTarget 'program\soffice.com') --version
