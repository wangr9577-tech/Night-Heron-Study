param([string]$Label = 'Night-Heron-Windows-x64')
$ErrorActionPreference = 'Stop'
if ($Label -notmatch '^[A-Za-z0-9_-]+$') { throw 'Use a simple package label.' }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$release = Join-Path $repoRoot 'app/build/windows/x64/runner/Release'
if (-not (Test-Path (Join-Path $release 'zhi_ai.exe'))) { throw 'Build the Windows release first.' }
$destination = Join-Path $repoRoot ('output/windows/' + $Label + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $destination | Out-Null
Get-ChildItem -LiteralPath $release | Copy-Item -Destination $destination -Recurse
# App-local Microsoft C++ redistributables; no system installer is needed.
$redist = 'C:/Program Files (x86)/Microsoft Visual Studio/18/BuildTools/VC/Redist/MSVC/14.50.35710/x64/Microsoft.VC145.CRT'
if (Test-Path -LiteralPath $redist) {
    Get-ChildItem -LiteralPath $redist -Filter '*.dll' | Copy-Item -Destination $destination
}
@'
啄知 AI · Windows 桌面版

解压后运行 zhi_ai.exe。请保留同目录下的 data 和全部 DLL。
本机课程、资料、专注记录和积分保存在 Windows 应用数据目录，无需注册或启动后端服务器。
AI 问答和组卷需在“AI 模型设置”中填写自己的兼容服务地址、模型和 API Key。
手机与电脑的数据分别保存在各自设备，不会自动同步。
Windows OCR 需要系统安装对应的 OCR 语言包；识别内容与 AI 生成题目均请核对。
'@ | Set-Content -Encoding utf8 (Join-Path $destination '开始使用.txt')
$archive = $destination + '.zip'
Compress-Archive -LiteralPath $destination -DestinationPath $archive
Get-FileHash -LiteralPath $archive -Algorithm SHA256 | Format-List
Write-Output ('Executable: ' + (Join-Path $destination 'zhi_ai.exe'))
Write-Output ('Archive: ' + $archive)
