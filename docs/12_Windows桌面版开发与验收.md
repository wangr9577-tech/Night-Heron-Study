# Windows 桌面版开发与验收

本轮增加 Windows x64 原生桌面客户端，复用现有 Flutter 应用。它是可直接运行的桌面程序；本机模式不需要注册、Python 环境或自建后端服务器。

## 使用方式

解压 Windows 发布包，双击 `zhi_ai.exe`，保留同目录全部 DLL 和 `data` 目录。侧栏提供本机课程、专注与统计、宠物、AI 模型设置和 AI 问答。

建立本机课程后可导入 TXT、Markdown、PDF、PNG/JPEG。PDF 可提取文字和查看原件，图片可使用 Windows 系统 OCR，识别结果可修改后保存。公式与表格使用现有 Markdown 数学渲染器。

需要 AI 时填写自己的兼容 Chat Completions 服务地址、模型和 API Key，可查询服务模型列表。选择资料并点击生成后，App 直接访问所配置服务；AI 出题结果需核对、修改和确认后才保存为本机试卷。当前组卷为简短答案题，提交后按文字匹配判分。

电脑和手机的数据分别保存在各自设备，尚无自动同步。PC 的 SQLite 数据库及资料副本位于 Windows 应用数据目录；模型密钥沿用安全存储，不写入普通配置文本。既有服务器模式为可选功能，Windows 默认后端地址为 `http://127.0.0.1:8000`。

## 桌面适配

- 新增 `app/windows/` 原生窗口、标题、构建和运行资源。
- `local_platform.dart` 为 Windows 初始化 FFI SQLite，并设置应用专用数据库目录。
- `desktop_shell.dart` 提供宽屏侧栏；窄窗口回到纵向布局，课程子页通过正常返回流程离开。
- `focus_page.dart` 在宽屏中并排显示热力图和时长分布，在手机及窄窗口中保持纵向排列。
- `desktop_pdf.dart` 使用 pdfrx/PDFium 在本机提取 PDF 文本、计页和渲染页面；页面渲染限制长宽，避免极长页面产生过大的位图。
- Windows OCR 使用 `Windows.Media.Ocr`，在工作线程处理图像后回到窗口线程回复；关闭窗口时回收任务。Android 保留 ML Kit 路径。

## 验证结果

- Windows Release 原生构建成功，并实际启动桌面进程。
- 静态检查无问题，现有 47 项 Flutter 测试全部通过。
- Windows 集成验收使用独立临时数据库：课程重开、PDF 原件字节一致、文本提取、页面渲染、合成图片英文 OCR、密钥保存和读取、回环模拟 AI 请求、生成试卷落库、专注记录和侧栏导航通过。
- Windows OCR 实测验证合成图中的英文 `ACCURACY`。语言选择已接入系统 OCR；中文及复杂公式的识别准确率仍需使用对应 Windows OCR 语言包和实际资料核对。
- 宽屏日历与饼图已经截图目视检查：`output/windows-test/desktop-focus.png`。
- Android 调试包兼容构建通过，日志 `output/flutter/windows-android-compatibility.log`。本轮没有替换用户模拟器中的安卓安装包。

证据日志：`windows-analyze-delivery.log`、`windows-tests-delivery.log`、`windows-integration-final.log`、`windows-build-packaged.log`，均位于 `output/flutter/`。测试数据与真实用户模型配置分离，测试中临时修改的模型配置会恢复。

## 开发构建

开发机需要 Flutter、Visual Studio C++ 工具链、Windows SDK，以及语音插件依赖的 NuGet 与 ATL。运行用户只需发布包，无需这些开发工具。

```powershell
.\scripts\build-windows.ps1 -RunDesktopTest
.\scripts\package-windows.ps1
```

脚本默认工具目录为 `D:/nh-toolchain`，可用 `-ToolchainRoot` 指定。若系统禁止开发用符号链接，构建脚本会在项目生成目录使用 junction，不修改 Windows Developer Mode。

这台开发机的 ATL 系统安装需要管理员权限，本轮未更改系统安装；使用已安装 Visual Studio 目录中的官方 catalog 取得与 MSVC 14.50 匹配的 Headers / X64 组件，核验 SHA-256 后解压至 `D:/nh-toolchain/atl-14.50`，通过 `ZHI_ATL_ROOT` 供构建使用。来源与哈希记录在该目录的 `provenance.json`。这些开发头文件不进入发布包。已有正规 ATL 安装的开发机不需要该变量。

PDF 库的官方用法见 [pdfrx 文档](https://pub.dev/packages/pdfrx)；NuGet 工具来自[微软官方安装文档](https://learn.microsoft.com/en-us/nuget/install-nuget-client-tools)，下载后已核对 Microsoft 签名。

## 当前限制

真实外部模型未使用用户密钥联调，不能由模拟服务测试推断其额度或生成质量。当前不包含跨设备自动同步、完整备份恢复、复杂题型组卷或语义评分。OCR 依赖系统对应语言功能，公式、表格及扫描件必须人工核对。语音模块可调用设备引擎，但未通过人工听音或实际麦克风验收。本轮仅在本地开发、构建与测试，未提交或推送 GitHub。


## 本轮交付文件

- 当前发布包：`output/windows/Night-Heron-Windows-x64-20261110-234517.zip`，大小 21.6 MiB。
- 解压运行入口：`output/windows/Night-Heron-Windows-x64-20261110-234517/zhi_ai.exe`。
- SHA-256：`0c4754271a55900b19e8aecf5a74ebe3f2478fb84c6278d3506f36b822cf0176`。
- ZIP 的 46 个条目已完成 CRC 完整性检查；程序及 AOT 数据与最终 Release 构建一致。
- 已启动的发布版窗口标题为“啄知 AI · Night Heron Study”，进程正常响应；实际窗口截图 `output/windows-test/windows-release-final.png` 已目视检查。
- 机器验收记录：`output/windows/acceptance.json`。


## 2026-11-11 命名调整

宠物模块在 Android 和 Windows 的入口、页面标题及相关操作中统一称为“宠物”，保留夜鹭形象。47 项回归测试通过，两个平台均重新构建。

- 当前 Windows 包：`output/windows/Night-Heron-Windows-x64-20261111-081758.zip`。
- 当前 Android 包：`output/flutter/Night-Heron-Android-20261111-debug.apk`。
