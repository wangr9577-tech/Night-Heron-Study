# 啄知 AI · Night Heron Study

啄知 AI 是面向大学生课程学习的 Flutter Android 与 Windows 桌面应用。本机模式免注册，课程资料、试卷、专注记录和宠物成长保存在设备上；配置模型后，App 直接调用用户选择的 AI 服务进行问答和资料出题。既有服务器模式通过 FastAPI 与 SQLite 后端访问学习服务。

本机模式的操作路径、当前安装包及验证边界见 [本地 AI 组卷验收](docs/10_2026-11-10_本地AI组卷验收.md)。服务器模式的构建与验证见 [本地测试报告](docs/04_本地测试报告.md)；各模块的本机覆盖范围见 [Android 本地化改造记录](docs/09_Android本地化改造记录.md)。

Windows 版的运行、构建和验收见 [Windows 桌面版](docs/12_Windows桌面版开发与验收.md)。

## 项目结构

```text
app/                 Flutter Android / Windows 客户端
app/lib/             本机资料、AI 接入、专注统计、宠物及可选服务器界面
app/windows/         Windows 原生窗口与系统 OCR
app/test/            Flutter 单元与组件测试
app/integration_test/ Android / Windows 运行测试和合成资料
backend/app/         A：用户、课程、任务、伴学、积分及应用组装
backend/engine/      B：学习引擎基础与数据库
backend/{materials,knowledge,tutoring,lessons,exams,mistakes,assessment,review}/
                     B：资料、教学、练习、判分与复习模块
contracts/           甲乙接口与共享数据模型
tests/               学习引擎和跨模块测试
backend/tests/       A 端后端测试
scripts/             开发和测试脚本
docs/                协作、运行、演示及测试记录
```

`backend/app/main.py` 组装 A 后端和 B 学习引擎；A 管理账号、课程权限、任务与奖励，B 管理资料、题目、作答证据和学习状态。数据与生成文件保存在本地，不作为源码提交。

## 开始体验

本机模式直接打开 App 即可使用，无需启动自建后端。首次没有服务器会话时进入本地体验；已有服务器会话可点击顶部手机图标进入。AI 生成操作需要在模型设置中填写兼容 Chat Completions 的服务地址、模型和 API Key。资料只在用户主动选择并点击发送时交给所配置服务，数据不会自动同步至既有服务器，也不会在手机和电脑之间自动同步。

开发环境为 Flutter 3.47.9 / Dart 3.13.7（本机已验证版本），以及目标平台的 Android SDK 或 Visual Studio C++ / Windows SDK。`app/pubspec.lock` 与 `uv.lock` 一并提交，用于固定已验证的依赖。

```powershell
cd app
flutter pub get --enforce-lockfile
flutter test
flutter build apk --debug
# 在已配置 C++ 工具链的 Windows 上：
flutter build windows --release
```

Windows 构建依赖及可选的本机辅助脚本见 [Windows 桌面版](docs/12_Windows桌面版开发与验收.md)。源码仓库不包含安装包、数据库、个人资料或 API Key；本地验收报告中的 `output/` 路径仅指开发机生成的文件，其他开发者需自行构建或运行测试生成。

使用既有服务器模式时：

1. 按 [Android 本地运行指南](docs/03_Android本地运行与功能演示.md) 启动后端及 Android 模拟器或设备。
2. 按指南导入本地学习资料，体验资料解析、课程讲解、练习和学习安排。
3. 对照 [本地测试报告](docs/04_本地测试报告.md) 查看已经验证的范围及尚待验证的事项。

开发者还可查看 [B1–B8 功能与验收边界](docs/07_B部分范围与验收.md)、[Android 隔离自动化](docs/06_Android隔离自动化.md) 和 [课程审核权限管理](docs/06_课程审核权限.md)。

宠物的图集格式与可选生成服务参见 [迷你宠物图集与生成](docs/08_迷你宠物图集与生成.md)；文字排版与动画的参考仓库见 [技术选型](docs/08_排版与宠物技术选型.md)。

项目使用的 KNN 讲义取自本机学习目录，仅供本地体验，原始文件不包含在仓库内。

## 能力边界

服务器模式的学习内容和作答评价通过 B 引擎处理。伴学聊天和口语反馈的具体实现及限制请查看 [本地测试报告](docs/04_本地测试报告.md)；演示回复不应表述为已接入外部大模型。本地体验的用户可自行配置兼容模型服务，真实服务是否可用须独立验证。Android 语音识别、朗读和通知的实际表现还依赖设备与权限。

## 开发验证

可选后端使用 Python 3.11+ 和 `uv`，在仓库根目录运行：

```powershell
uv sync --extra dev --locked
uv run pytest
uv run uvicorn backend.app.main:app --host 127.0.0.1 --port 8000
```

无个人资料时也可使用 `examples/inputs/basic.md` 和测试中的合成 PDF / 图片验证功能。`scripts/seed_knn_demo.py --source <本机PDF路径>` 仅用于自愿导入已有讲义，原件不随仓库上传。

更多后端测试、Android 构建及环境变量见 [Android 本地运行指南](docs/03_Android本地运行与功能演示.md)。原 [甲方开发阶段审核报告](docs/02_交付审核报告.md) 保留 2026-11-06 时的历史状态，不代表当前联调结果。
