param(
    [string]$ToolchainRoot = 'D:/nh-toolchain',
    [switch]$RunDesktopTest
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$appRoot = Join-Path $repoRoot 'app'
$env:PUB_CACHE = Join-Path $ToolchainRoot 'pub-cache'
$env:PATH = (Join-Path $ToolchainRoot 'nuget') + ';' + (Join-Path $ToolchainRoot 'flutter/bin') + ';' + $env:PATH
if (Test-Path (Join-Path $ToolchainRoot 'atl-14.50/include/atlstr.h')) {
    $env:ZHI_ATL_ROOT = Join-Path $ToolchainRoot 'atl-14.50'
}
Push-Location $appRoot
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) {
        # Junctions support Flutter plugins without changing Windows Developer Mode.
        $configuration = Get-Content '.flutter-plugins-dependencies' -Raw | ConvertFrom-Json
        $links = Join-Path $appRoot 'windows/flutter/ephemeral/.plugin_symlinks'
        New-Item -ItemType Directory -Path $links -Force | Out-Null
        foreach ($plugin in $configuration.plugins.windows) {
            $destination = Join-Path $links $plugin.name
            if (-not (Test-Path -LiteralPath $destination)) {
                New-Item -ItemType Junction -Path $destination -Target (Resolve-Path -LiteralPath $plugin.path).Path | Out-Null
            }
        }
        flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'Unable to prepare Flutter packages.' }
    }
    if ($RunDesktopTest) {
        flutter test integration_test/windows_local_test.dart -d windows --no-pub --dart-define=DESKTOP_TEST_ISOLATED=true
        if ($LASTEXITCODE -ne 0) { throw 'Windows runtime acceptance failed.' }
    }
    flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
    Write-Host ('Windows app: ' + (Join-Path $appRoot 'build/windows/x64/runner/Release/zhi_ai.exe'))
} finally { Pop-Location }
