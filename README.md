# 啄知 AI — 甲的开发交付

依据《啄知AI_模块任务拆分与双人分工方案》（2026-11-02），本仓库实现 **甲** 负责的全部业务：

- `app/` — Flutter App（F1–F9 全部前端页面，含口语陪练嵌入 AI 伴学页）
- `backend/` — FastAPI + SQLite 后端（A1–A8 甲的业务模块 + core 公共工程 + mock_b 乙接口契约桩）
- `contracts/` — 双方共同维护的数据契约、契约样例（fixtures）与接口变更记录（甲负责起草维护）
- `docs/` — 任务拆分、派发计划、审核报告

乙负责的模块（B1–B8 资料、图谱、教学、题目、掌握状态、间隔复习）按约定**不在本仓库交付**，
由 `backend/app/mock_b` 按 `contracts/CONTRACTS.md` 的完全相同接口提供契约样例数据，
前端与甲的后端先用样例数据独立开发，联调时替换为乙的真实服务。

## 目录结构

```
zhi-ai/
├─ app/                     # Flutter 前端（F1–F9）
├─ backend/
│  ├─ .venv/                # Python 3.13 虚拟环境（fastapi/uvicorn/sqlalchemy/pytest/httpx）
│  ├─ app/
│  │  ├─ core/              # 甲的公共工程：应用工厂、模块自动注册、DB、鉴权依赖、错误结构、后台任务
│  │  ├─ accounts/          # A1 用户与权限
│  │  ├─ courses/           # A2 课程与目标
│  │  ├─ planner/           # A3 学习计划 + A4 任务执行与重排
│  │  ├─ companion/         # A5 宠物与伴学
│  │  ├─ rewards/           # A6 积分与投喂（成果事件消费与去重）
│  │  ├─ speech/            # A7 语音与口语陪练（TTS/ASR 可插拔引擎 + 音频缓存）
│  │  ├─ notifications/     # A8 提醒与通知
│  │  ├─ mock_b/            # 乙 B1–B8 接口的契约桩（按 contracts/ 提供样例数据）
│  │  └─ main.py            # uvicorn 入口：app.main:app
│  ├─ data/                 # SQLite 数据文件（运行时生成）
│  ├─ tests/                # pytest 测试
│  └─ run.ps1               # 启动脚本
├─ contracts/
│  ├─ CONTRACTS.md          # 接口契约（单一事实来源）
│  ├─ CHANGELOG.md          # 接口变更记录
│  └─ fixtures/             # 契约样例数据（mock_b 与前端 Fake 共用）
├─ docs/
│  └─ 01_任务拆分与派发计划.md
└─ tools/
   └─ env.ps1               # 开发环境变量（Flutter 国内镜像、PATH）
```

## 启动

```powershell
# 后端（http://127.0.0.1:8000，文档 /docs）
cd backend
.\.venv\Scripts\python.exe -m uvicorn app.main:app --port 8000

# 测试
.\.venv\Scripts\python.exe -m pytest -q

# App（Web 预览；比赛真机可用 Android，见 docs）
cd app
flutter run -d web-server --dart-define=API_BASE=http://127.0.0.1:8000
flutter build web --dart-define=API_BASE=http://127.0.0.1:8000
```

演示账号：`demo / demo1234`（预置课程"高考数学·样例"，含样例资料/图谱/课程/题目/错题/复习/事件数据）。

## 约定

- 全部接口契约以 `contracts/CONTRACTS.md` 为准；改字段先记 `contracts/CHANGELOG.md`。
- 跨模块只经服务函数/接口读取，不直接改对方模块数据表；学习状态唯一来源在"乙"侧。
- 积分结算只消费乙的成果事件，按 `event_id` 去重，重复读取不重复发奖。
