# 运行 Android App 并体验学习流程

本指南面向本机开发和功能演示。功能是否通过最终端到端验证，以 [本地测试报告](04_本地测试报告.md) 的实际记录为准。

## 准备环境

- Windows、Python 3.11+、`uv`，Flutter SDK、Android SDK 和 JDK。
- 一个可用的 Android 模拟器，或通过 USB 调试连接的手机。
- 项目目录为 `D:\软件大赛\Night-Heron-Study-app`。当前机器另有指向此目录的短路径 `D:\nh-app`，便于 Android 工具处理中文路径。其他机器请替换为自己的项目路径。
- 本机体验资料为 `D:\Study\Data Science & Machine Learning\Courses\Introduction to Data Science\Ch4 Classification\Notes\Ch4 K-Nearest Neighbors.pdf`。资料仅供本地使用，公开分享前需确认权限。

## 启动后端

在 PowerShell 中执行，并保持窗口运行：

```powershell
cd 'D:\软件大赛\Night-Heron-Study-app'
uv sync --frozen --extra dev
.\.venv\Scripts\python.exe scripts\seed_knn_demo.py
.\.venv\Scripts\python.exe -m uvicorn backend.app.main:app --host 127.0.0.1 --port 8000
```

初始化脚本从本机 KNN 讲义准备账号与示例课程，账号 `demo_knn`，密码 `Demo12345`。若讲义位于其他位置，可在脚本后添加 `--source '完整文件路径'`。脚本和初始化结果仍需按 [测试报告](04_本地测试报告.md) 核对实际验证状态。

检查 `http://127.0.0.1:8000/healthz` 可确认服务响应；接口文档位于 `http://127.0.0.1:8000/docs`。默认数据存放在 `backend/data/`。如需隔离数据，可在初始化及启动前设置同一组 `ZHI_DB_PATH`（A 数据库完整路径）和 `ZHUOZHI_DATA_DIR`（B 数据目录），不要覆盖已有数据。

## 启动 Android 客户端

另开 PowerShell，使用已安装的 Flutter、Android SDK 和 JDK：

```powershell
$env:JAVA_HOME = 'D:\nh-toolchain\jdk-21.0.13+9'
$env:ANDROID_HOME = 'D:\nh-toolchain\android-sdk'
$env:ANDROID_USER_HOME = 'D:\nh-toolchain\android-user'
$env:ANDROID_AVD_HOME = 'D:\nh-toolchain\avd'
$env:GRADLE_USER_HOME = 'D:\nh-toolchain\gradle'
$env:PUB_CACHE = 'D:\nh-toolchain\pub-cache'
$env:PATH = 'D:\nh-toolchain\flutter\bin;D:\nh-toolchain\android-sdk\platform-tools;' + $env:PATH
cd D:\nh-app\app
flutter pub get
flutter devices
flutter run -d <设备ID> --dart-define=API_BASE=http://10.0.2.2:8000
```

标准 Android 模拟器通过 `10.0.2.2` 访问电脑本机，后端可继续监听 `127.0.0.1`。如需使用设备中的 `127.0.0.1`，可先运行 `adb -s <设备ID> reverse tcp:8000 tcp:8000`，再将 `API_BASE` 设为 `http://127.0.0.1:8000`。App 登录界面也可修改后端地址。USB 真机同样可通过 `adb reverse` 访问开发机回环服务。

## 功能演示脚本

1. **登录与课程**：使用本地演示账号 `demo_knn` / `Demo12345` 登录并选择“数据科学导论 · KNN”，或注册账号，在“我的”创建新课程并填写目标、DDL、可用星期与时段。
2. **导入资料**：在“学习”选择“导入学习资料”，选取 KNN 讲义并上传，解析后逐块核对文字，需要时修正，再明确确认提取知识点。之后查看资料和知识图谱中的来源、掌握度和关系。使用模拟器时，先将 PDF 复制到下载目录：

   ```powershell
   adb -s <设备ID> push 'D:\Study\Data Science & Machine Learning\Courses\Introduction to Data Science\Ch4 Classification\Notes\Ch4 K-Nearest Neighbors.pdf' /sdcard/Download/
   ```

3. **讲解与问答**：选择已提取知识点生成课程讲解，翻页并退出后重新进入，查看位置是否恢复。点击朗读可尝试设备的语音引擎；在学习问答中提问并查看原文依据。
4. **练习与错题**：从练习卷或计划中的练习任务进入题目，独立作答并查看分数。按原卷生成时先检查识别结果，编辑并确认出题蓝图。可另选一道题故意答错，在错题本查看记录和变式。查看完整解析会记录辅助情况，可能影响掌握证据和积分。
5. **安排与积分**：在“安排”生成或查看推荐任务，从匹配的练习任务进入作答，完成后刷新安排及积分流水。通过真实证据满足任务条件时才能结算；重复同步不应重复发放奖励。
6. **伴学与提醒**：创建伙伴、查看等级与成长足迹，点击每日陪伴获取经验；查看积分、兑换食物并投喂，再尝试文本口语场景和站内通知。每日陪伴按北京时间每天第一次增加 3 经验，当天再次进入显示已陪伴。注意界面中的演示标记，实际语音识别和系统通知需在目标设备单独验证。
7. **自定义夜鹭**：在“伴学”进入“自定义伙伴”，修改名字和围巾配色并保存；也可上传符合格式的动画图集。描述生成需要管理员另行配置兼容的图集生成服务，当前没有配置真实图像模型。素材格式及服务合同见 [迷你宠物图集与生成](08_迷你宠物图集与生成.md)。

如需避免影响已有演示进度，使用新账号和独立课程。不要将个人教材、账号数据库或用户上传文件加入 Git。

## 验证命令

在仓库根目录运行后端测试：

```powershell
$env:ZHUOZHI_TEST_OCR = 'true'
.\.venv\Scripts\python.exe -m pytest
```

在 `app` 目录运行客户端检查和 Android 构建：

```powershell
flutter analyze
flutter test
flutter build apk --debug --dart-define=API_BASE=http://10.0.2.2:8000
```

调试 APK 用于本地验证；比赛提交前需按实际要求检查包名、签名、连接方式与设备兼容性。实际结果见 [本地测试报告](04_本地测试报告.md)。

## 课程审核

课程创建者可在“我的 → 课程成员管理”按用户 ID 添加成员；审核者的用户 ID 显示在自己的“我的”页面。成员不会自动获得审核权。服务端管理员需按 [课程审核权限](06_课程审核权限.md) 授权；审核者随后可在“我的 → 内容与作答审核”核对错题原件、选择来源并确认答案，或审核主观题。审核者不能审核自己的记录。
