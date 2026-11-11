# Android 隔离设备自动化

`app/integration_test/app_flow_test.dart` 会清除设备上的应用登录配置、写入题目和学习任务，Flutter 结束测试时也可能卸载应用。只在专用模拟器和独立数据库中运行；不要指向正在使用的模拟器或演示后端。

本机的可复现方式：

1. 先确认专用 AVD `zhi_audit_5582` 已作为 `emulator-5582` 启动。脚本会核对 AVD 名称，若设备不匹配则拒绝运行。
2. 在仓库根目录的 PowerShell 中执行：

   ```powershell
   .\scripts\test-android-isolated.ps1
   ```

   脚本默认在空闲的 `8014` 端口启动临时后端；若端口被占用，可改用 `-BackendPort 其他空闲端口`。设备内的 `127.0.0.1:8000` 通过该专用设备的 `adb reverse` 指向临时后端。脚本结束时恢复之前的反向映射，并停止它启动的后端进程。

3. 每次运行都会在 `output/android-integration-runs/` 下新建独立目录，保存初始化、后端及 Flutter 测试日志和测试数据。初始化使用本机 KNN 讲义；找不到讲义时脚本会失败并保留 `seed.log`。运行需要本机 `D:\nh-toolchain` 工具链和指向仓库的 `D:\nh-app` 路径，迁移机器时须相应修改脚本。

测试设计覆盖：登录隔离账号、生成题目和安排、从任务进入练习并作答、检查任务完成与积分，切换学习及伴学页面，并检查未获授权的用户进入审核页面时得到权限提示。实际是否通过以本轮日志为准；它不是全部功能或真机能力的验收。Flutter 测试会重建 `app/build/` 下的调试 APK；日常演示包保存在 `output/flutter/Night-Heron-Study-debug.apk`。
