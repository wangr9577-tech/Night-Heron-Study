# 啄知 AI

本项目按《啄知AI_模块任务拆分与双人分工方案》推进甲负责的 Flutter App 与后端。当前仍在开发和联调中，不能视为方案全部完成。

## 目前状态

- `backend/app/core.py`、`main.py`：FastAPI 与 SQLite 基础、注册登录、课程及成员、手动任务、排程和调整。接口以 `contracts/CONTRACTS.md` 为目标；候选推荐和学习快照是标注 `is_demo` 的演示数据。
- `backend/app/extra.py`：宠物、奖励、语音及通知接口；实际能力与限制见源码和最终审核报告。默认演示语音不等于真实语音合成或识别。
- `backend/app/demo_b.py`：仅供联调的示例资料、图谱、课程、问答、练习等部分乙侧接口；数据不代表真实课程或学习成果。试卷等乙侧能力未完整实现。
- `backend/app/event_feed.py`：可配置的乙侧学习事件读取适配器；默认未配置，演示事件接口为空且不会发奖。
- `app/`：Flutter 客户端，具体页面与后端联调状态见最终审核报告。
- `contracts/`：拟定接口契约；真实乙侧接口尚需双方联调确认。

## 运行后端

使用 Python 3.10 或更新版本，在 `backend` 目录创建虚拟环境并安装依赖：

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

接口文档为 `http://127.0.0.1:8000/docs`。用户需要自行注册；当前没有预置演示账号。SQLite 默认存储在 `backend/data/zhi.db`，也可通过 `ZHI_DB_PATH` 指定路径。已有 `.venv` 如指向不存在的 Python，请先重新创建。

要联调真实学习事件，在启动后端前设置 `ZHI_B_BASE_URL` 为可信乙服务的 API 前缀，例如 `$env:ZHI_B_BASE_URL='https://example.org/api/v1'`。服务端将当前用户的 Bearer 令牌转发给该服务，故乙服务必须信任同一令牌、按用户过滤事件并提供契约中的稳定分页游标；仅对可信服务配置该地址。除本机回环地址外必须使用 HTTPS。用户调用 `POST /api/v1/rewards/consume-events` 手动拉取一页，游标和事件去重记录持久化，末页会安全重读。尚无后台自动拉取，真实乙服务和令牌互通尚未验证。不要将项目内演示服务配置为真实事件源。

测试：`.\.venv\Scripts\python.exe -m pytest -q`。受限 Windows 沙箱中如临时目录或事件循环不可用，请使用可正常运行事件循环的环境，并将 pytest `--basetemp` 指向可写目录。

## 运行 App

在安装 Flutter SDK 并取得依赖后，进入 `app` 目录执行：

```powershell
flutter pub get
flutter run --dart-define=API_BASE=http://127.0.0.1:8000
```

Android 模拟器或真机访问开发电脑后端时，`API_BASE` 必须改为该设备可访问的地址；电脑的 `127.0.0.1` 并不指向手机。发布前应为服务配置 HTTPS、持久化部署及生产环境安全设置。
