# 啄知 AI 开发环境（所有子智能体在 pwsh 里先执行：  . E:\大学\大三上\夜露\zhi-ai\tools\env.ps1）
# 重要：本机出网必须走系统代理，pip / flutter pub / git / curl 都需要这几个环境变量。
$env:HTTP_PROXY  = 'http://127.0.0.1:7897'
$env:HTTPS_PROXY = 'http://127.0.0.1:7897'
$env:NO_PROXY    = 'localhost,127.0.0.1'
$env:PATH = 'E:\flutter\bin;' + $env:PATH
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$ZHI_ROOT = 'E:\大学\大三上\夜露\zhi-ai'
$ZHI_PY = "$ZHI_ROOT\backend\.venv\Scripts\python.exe"
Write-Host "env ready. python=$ZHI_PY ; proxy=$env:HTTPS_PROXY ; flutter=E:\flutter\bin"
