<# Run the destructive Android integration test against a disposable AVD and database.

Requires the dedicated zhi_audit_5582 AVD to be running as emulator-5582.
The test clears that AVD's app preferences and Flutter may uninstall the app.
The user's ordinary emulator and database are never selected by this script.
#>
param(
    [int]$BackendPort = 8014
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$shortApp = 'D:/nh-app/app'
$adb = 'D:/nh-toolchain/android-sdk/platform-tools/adb.exe'
$python = Join-Path $root '.venv/Scripts/python.exe'
$device = 'emulator-5582'
$avdName = (& $adb -s $device emu avd name 2>$null | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0 -or $avdName -ne 'zhi_audit_5582') {
    throw 'Start the dedicated zhi_audit_5582 AVD as emulator-5582 first. Refusing to use another device.'
}
if (Get-NetTCPConnection -LocalPort $BackendPort -State Listen -ErrorAction SilentlyContinue) {
    throw "Port $BackendPort is already in use; select an unused backend port."
}

$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$runDir = Join-Path $root "output/android-integration-runs/$runId"
New-Item -ItemType Directory -Path $runDir | Out-Null
$oldVars = @{}
$vars = @{
    ZHI_DB_PATH = (Join-Path $runDir 'zhi.sqlite')
    ZHUOZHI_DATA_DIR = (Join-Path $runDir 'learning')
    JAVA_HOME = 'D:/nh-toolchain/jdk-21.0.13+9'
    ANDROID_HOME = 'D:/nh-toolchain/android-sdk'
    ANDROID_USER_HOME = 'D:/nh-toolchain/android-user'
    ANDROID_AVD_HOME = 'D:/nh-toolchain/avd'
    GRADLE_USER_HOME = 'D:/nh-toolchain/gradle'
    PUB_CACHE = 'D:/nh-toolchain/pub-cache'
    NO_PROXY = 'localhost,127.0.0.1,::1'
    PATH = 'D:/nh-toolchain/flutter/bin;D:/nh-toolchain/android-sdk/platform-tools;' + $env:PATH
}
foreach ($key in $vars.Keys) {
    $oldVars[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    [Environment]::SetEnvironmentVariable($key, $vars[$key], 'Process')
}
$backend = $null
$serverPid = $null
$previousReverse = (& $adb -s $device reverse --list | Select-String 'tcp:8000\s+tcp:(\d+)')
$previousPort = if ($previousReverse) { $previousReverse.Matches[0].Groups[1].Value } else { $null }
try {
    & $python (Join-Path $root 'scripts/seed_knn_demo.py') *> (Join-Path $runDir 'seed.log')
    if ($LASTEXITCODE -ne 0) { throw "Failed to seed isolated data; see $runDir/seed.log" }
    $backend = Start-Process -FilePath $python -ArgumentList @('-m', 'uvicorn', 'backend.app.main:app', '--host', '127.0.0.1', '--port', "$BackendPort") -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runDir 'backend.log') -RedirectStandardError (Join-Path $runDir 'backend-error.log')
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        $listener = Get-NetTCPConnection -LocalPort $BackendPort -State Listen -ErrorAction SilentlyContinue
        if ($listener) {
            $server = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
            if ($server.ParentProcessId -ne $backend.Id -and $server.ProcessId -ne $backend.Id) {
                throw "Another process took port $BackendPort; refusing to run."
            }
            $serverPid = $server.ProcessId
            try { $ready = (Invoke-RestMethod -TimeoutSec 2 "http://127.0.0.1:$BackendPort/healthz").ok } catch {}
            if ($ready) { break }
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw "Isolated backend failed to start; see $runDir/backend-error.log" }
    & $adb -s $device reverse tcp:8000 "tcp:$BackendPort" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to configure isolated ADB reverse.' }
    Push-Location $shortApp
    try {
        & flutter test integration_test/app_flow_test.dart -d $device --dart-define=INTEGRATION_TEST_ISOLATED=true --dart-define=API_BASE=http://127.0.0.1:8000 --reporter expanded *>&1 | Tee-Object -FilePath (Join-Path $runDir 'flutter-test.log')
        if ($LASTEXITCODE -ne 0) { throw "Integration test failed; see $runDir/flutter-test.log" }
    } finally { Pop-Location }
    Write-Host "Isolated Android test passed. Logs: $runDir"
} finally {
    if ($previousPort) { & $adb -s $device reverse tcp:8000 "tcp:$previousPort" | Out-Null }
    else { & $adb -s $device reverse --remove tcp:8000 | Out-Null }
    if ($serverPid) { Stop-Process -Id $serverPid -ErrorAction SilentlyContinue }
    if ($backend) { Stop-Process -Id $backend.Id -ErrorAction SilentlyContinue }
    foreach ($key in $oldVars.Keys) { [Environment]::SetEnvironmentVariable($key, $oldVars[$key], 'Process') }
}
