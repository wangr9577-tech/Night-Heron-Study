# 啄知 AI 接口契约（单一事实来源）

> 甲起草并维护；乙的真实服务实现须与本文完全一致，联调时以 `mock_b` 桩为行为参照。
> 变更须先记 `contracts/CHANGELOG.md`。字段只增不改不删；新字段保持向后兼容。

## 0 全局约定

- Base URL：`http://127.0.0.1:8000`，接口前缀 `/api/v1`。
- 认证：`Authorization: Bearer <access_token>`。除 `/auth/register`、`/auth/login`、`/healthz` 外全部需要认证，缺失/无效 → `401 unauthorized`。
- 课程权限：所有 `/courses/{course_id}/...` 及其下资源必须调用 `require_course_access(user_id, course_id)`（成员或 owner 即通过），失败 → `403 no_course_access`。**用户间数据严格隔离。**
- 成功响应：直接返回 JSON 对象；列表一律包装为 `{"items": [...], ...可选分页字段}`。
- 错误响应：HTTP 状态码 + `{"error_code": string, "message": string, "detail": object|null}`。
  `error_code` 枚举：`invalid_request`(400) `unauthorized`(401) `no_course_access`(403) `not_found`(404) `conflict`(409) `business_rule`(422) `internal`(500)。
- 时间：时间戳一律 UTC ISO-8601 带 `Z`（如 `2026-11-05T04:00:00Z`）；日期 `YYYY-MM-DD`；时刻 `HH:MM`；星期 1–7（周一=1）。
- ID：小写前缀 + 20 位 base32（如 `tsk_01JZK3...`），一经生成稳定不变。前缀：`usr crs mem_ usrmsg tsk job aud ntf tx itm pet msg con les pg qst att evt mat nod exm msk rev cand seg`。
- 游标分页：`?cursor=&limit=`（limit 默认 50，最大 200），返回 `next_cursor`（到底为 `null`）。
- 后台任务（跨模块统一形态）：`job = {job_id, module, status: "pending|running|succeeded|failed", progress: 0-100, result_ref: string|null, error_code: string|null, retryable: bool, created_at, updated_at}`；查询 `GET /api/v1/jobs/{job_id}`；重试 `POST /api/v1/jobs/{job_id}/retry`（`retryable=false` → `business_rule`）。前端统一用 `JobProgressCard` 展示；任务在后台继续，可重复查询不重复生成。

## 1 对象定义

### 1.1 user（A1）
```json
{"user_id":"usr_…","username":"demo","nickname":"演示同学","avatar_key":"bird_1",
 "settings":{"theme":"system","notify_dnd":{"start":"23:00","end":"07:00"}},
 "created_at":"2026-11-01T00:00:00Z"}
```

### 1.2 course（A2）
```json
{"course_id":"crs_…","owner_user_id":"usr_…","title":"高考数学·样例","subject":"数学",
 "goal_text":"期中提升到 120 分","ddl":"2026-12-20",
 "available_slots":[{"weekday":3,"start":"19:00","end":"21:00"},{"weekday":6,"start":"09:00","end":"11:30"}],
 "role":"owner","archived":false,"created_at":"…","updated_at":"…"}
```
成员：`POST /courses/{course_id}/members {user_id, role:"member"}`；`GET` 列表同路径。

### 1.3 task（A3/A4，甲排程）
```json
{"task_id":"tsk_…","course_id":"crs_…",
 "type":"lesson|practice|exam|mistake|review|qa","target_id":"les_…","title":"复习：三角函数图像变换",
 "status":"pending|in_progress|partial|done|postponed|pinned|cancelled",
 "planned_date":"2026-11-07","planned_time_slot":"19:00","estimated_minutes":40,
 "reason":"错题连续 2 次错误且临近 DDL","source":"recommended|manual",
 "candidate_id":"cand_…|null","suggested_due_at":"2026-11-09T12:00:00Z|null",
 "completed_at":"…|null","progress_percent":null,
 "reschedule_history":[{"from_date":"2026-11-06","to_date":"2026-11-07","reason":"ddl_shift","at":"…"}]}
```
- `suggested_due_at`（乙建议，只读保留）与 `planned_date/planned_time_slot`（甲实排）**分别保存**。
- 跳转：`GET /planner/tasks/{task_id}/route` → `{type, target_id, course_id, route}`，route 用 `docs/01` 的映射表。
- 完成判定：`practice/exam/mistake` 类任务**不**由前端声明完成，由 A6 消费乙的 `task_criteria_met` 事件置为 `done`；`lesson/qa/review` 可由用户手动 complete。

### 1.4 recommended_item（B8 → 甲）
```json
{"candidate_id":"cand_…","type":"lesson|practice|exam|mistake|review|concept","target_id":"con_…",
 "title":"补学：导数的几何意义","estimated_minutes":25,
 "reason":"掌握度 0.32，是 3 个待学知识点的前置","suggested_due_at":"2026-11-09T12:00:00Z"}
```

### 1.5 learning_event（B8 → 甲，唯一 ID，只追加）
```json
{"event_id":"evt_…","user_id":"usr_…","course_id":"crs_…","source_task_id":"tsk_…|null",
 "event_type":"practice_submitted|practice_graded|task_criteria_met",
 "result":{"question_id":"qst_…|null","score":8,"max_score":10,"passed":true},
 "occurred_at":"2026-11-05T12:30:00Z"}
```
读取：`GET /learning-events?cursor=&course_id=&limit=` → `{events:[learning_event], next_cursor}`（按当前用户过滤）。消费方（A6）成功落库后才推进游标；按 `event_id` 唯一约束去重。

### 1.6 教学页面（B4 → 甲渲染）
```json
{"lesson_id":"les_…","course_id":"crs_…","title":"三角函数图像变换","page_count":3,
 "pages":[{"page_id":"pg_…","order":1,
   "elements":[{"element_id":"el_y1","type":"text|formula|image|list|code","content":"…"}],
   "explanation_segments":[{"segment_id":"seg_…","order":1,"text":"先平移后伸缩…",
     "highlight_element_ids":["el_y1"]}]}]}
```
语音：前端对 `explanation_segments` 调 A7 `POST /speech/tts/batch`（cache_key=`seg_id`）得音频后驱动高亮；TTS 失败 → 仅展示讲解稿文本。

### 1.7 attempt（B7 判定并保存；甲展示）
```json
{"attempt_id":"att_…","question_id":"qst_…","course_id":"crs_…","concept_ids":["con_…"],
 "answer":"x=2","score":8,"max_score":10,"is_correct":true,"hints_used":["hint_1"],
 "grading_basis":"步骤 1 正确；步骤 2 符号错误，扣 2 分","source_task_id":"tsk_…|null",
 "status":"submitted|graded","submitted_at":"…","graded_at":"…|null"}
```

### 1.8 knowledge node / edge（B2）
```json
{"node_id":"nod_…","concept_id":"con_…","name":"三角函数图像变换","description":"…",
 "mastery":0.62,"source_refs":[{"material_id":"mat_…","page":12,"block_id":"blk_…","snippet":"…"}]}
```
边：`{"from":"nod_a","to":"nod_b","relation":"prerequisite|related"}`（prerequisite 无环，可校验）。

### 1.9 material（B1）
```json
{"material_id":"mat_…","course_id":"crs_…","title":"2026届一模数学","file_type":"pdf|pptx|image",
 "page_count":24,"status":"parsing|ready|failed","import_job_id":"job_…"}
```
详情含 `chapters:[{chapter_id,title,page_start}]`、`pages:[{page_no,blocks:[{block_id,type:"text|image|formula",text}]}]`。

### 1.10 mistake（B6）
```json
{"mistake_id":"msk_…","course_id":"crs_…","question_id":"qst_…",
 "image_ref":"/api/v1/files/…","recognized_question":"已知 f(x)=…","user_answer":"…",
 "correct_answer":"…","concept_ids":["con_…"],"error_cause":"概念混淆：导数符号",
 "step_explanations":[{"step":1,"text":"…","highlight":"f'(x)<0"}],
 "variants":[{"variant_id":"var_…","question_id":"qst_…","title":"变式 1"}],
 "attempts":[attempt],"created_at":"…"}
```

### 1.11 exam（B5）
```json
{"exam_id":"exm_…","course_id":"crs_…","source_material_id":"mat_…","status":"imported|blueprint_ready|generating|ready|failed",
 "blueprint":{"sections":[{"name":"单选","question_count":8,"score_each":5,"concept_weights":{"con_…":0.4}}],"total_score":150},
 "job_id":"job_…|null","result_ref":"/api/v1/exams/{id}/paper|null","export_ref":"/api/v1/exams/{id}/export|null"}
```

### 1.12 pet / memory / growth（A5）
```json
{"pet_id":"pet_…","user_id":"usr_…","name":"小啄","avatar_key":"bird_1",
 "personality":{"tone":"鼓励型","verbosity":"简洁"},"growth":{"level":3,"exp":120,"streak_days":5,"total_minutes":480},
 "created_at":"…"}
```
memory：`{memory_id, pet_id, content, source:"chat|system", created_at}`（可查改删）。
chat message：`{message_id, pet_id, role:"user|pet", content, ref_type:"task|point|null", ref_id, created_at}`。
growth event：`{event_id, pet_id, type:"feed|study|streak", exp_delta, at, ref_id}`。

### 1.13 points / item / bag（A6）
tx：`{tx_id, user_id, type:"earn|spend", amount, balance_after, reason, ref_type:"event|exchange|feed", ref_id, at}`；
shop item：`{item_id, name, kind:"food|tool|decoration", price, icon_key, desc}`；
bag：`{item_id, qty, last_used_at}`。

### 1.14 notification（A8）
`{ntf_id, user_id, type:"ddl|task_due|review_due|points|system", title, body, ref_type, ref_id, created_at, read_at}`；
settings：`{in_app_enabled:true, channels:{wechat:{enabled:false, template_id:null}}, dnd:{start:"23:00",end:"07:00"}, max_per_day:5, ddl_remind_hours:24}`。

### 1.15 review item（B8）
`{review_item_id, course_id, target_type:"question|concept|mistake", target_id, due_date, interval_days, ease, last_reviewed_at}`；
`POST /reviews/{review_item_id}/grade {quality:0-5}` → 更新后 item（SM-2）。

### 1.16 oral session（A7）
scene：`{scene_id, title, level:"基础|进阶", opening_text, target_turns}`；
turn：`{turn_id, user_text, corrected_text, reply_text, reply_audio_id, feedback:{expression_tips:[string], grammar_fix:string|null}}`。

## 2 接口清单（★=前端直接调用）

### A1 accounts（`/api/v1`）
- ★`POST /auth/register {username,password,nickname?}` → `{user, access_token}`（重名 409）
- ★`POST /auth/login {username,password}` → `{user, access_token}`（错 401 invalid_request）
- ★`POST /auth/logout` → `{"ok":true}`
- ★`GET /users/me` → user；★`PATCH /users/me {nickname?,avatar_key?,settings?}` → user

### A2 courses
- ★`GET /courses` → `{items:[course]}`（含 owner 与 member 的）
- ★`POST /courses {title,subject?,goal_text?,ddl?,available_slots?}` → course
- ★`GET/PATCH /courses/{course_id}`；★`POST /courses/{course_id}/archive` → course
- ★`GET/POST /courses/{course_id}/members`；`DELETE /courses/{course_id}/members/{user_id}`
- 内部：`require_course_access(user_id, course_id) -> bool`（accounts.services 提供实现，core.deps 注入，mock_b 与各模块统一调用）

### A3/A4 planner
- ★`GET /courses/{course_id}/planner/today?date=YYYY-MM-DD` → `{date, items:[task], summary:{total,done,points_today}}`
- ★`GET /courses/{course_id}/planner/calendar?month=YYYY-MM` → `{month, days:[{date, items:[task]}]}`
- ★`GET /courses/{course_id}/planner/candidates` → `{items:[recommended_item], snapshot_version, generated_at}`（代理乙快照）
- ★`POST /courses/{course_id}/planner/auto-generate {date}` → `{items:[task], skipped:[{candidate_id,reason}]}`（读乙快照+DDL+可用时段计算排程；同一 candidate 已有未取消任务则跳过）
- ★`POST /courses/{course_id}/planner/accept-recommendation {candidate_id, planned_date?, planned_time_slot?}` → task
- ★`POST /courses/{course_id}/planner/tasks {type,target_id,title,planned_date,planned_time_slot?,estimated_minutes?}` → task（手动）
- ★`GET /planner/tasks/{task_id}`；★`GET /planner/tasks/{task_id}/route` → `{type,target_id,course_id,route}`
- ★`POST /planner/tasks/{task_id}/complete {completion:"full|partial", progress_percent?}` → task
- ★`POST /planner/tasks/{task_id}/reschedule {to_date, to_slot?, reason?}` → task（写 reschedule_history，已完成字段保留）
- ★`POST /planner/tasks/{task_id}/pin {date|null}`；★`POST /planner/tasks/{task_id}/cancel`
- ★`GET /courses/{course_id}/planner/completions?month=` → `{items:[{task_id,title,completed_at,points_awarded}]}`（完成记录）

### A5 companion / A6 rewards
- ★`GET/POST /companion/pets`；★`GET/PATCH /companion/pets/{pet_id}`
- ★`GET /companion/pets/{pet_id}/chat?limit=&before=`；★`POST /companion/pets/{pet_id}/chat {content}` → `{reply: message, ref_type, ref_id}`（引用甲侧真实任务/积分；不读写掌握状态）
- ★`GET/PATCH/DELETE /companion/pets/{pet_id}/memories[/{memory_id}]`
- ★`GET /companion/pets/{pet_id}/growth-events`
- ★`GET /rewards/points` → `{balance, updated_at}`；★`GET /rewards/transactions?month=`
- ★`GET /rewards/shop`；★`POST /rewards/exchange {item_id, qty?}` → `{tx, bag_item}`（余额不足 business_rule）
- ★`GET /rewards/bag`；★`POST /rewards/feed {pet_id, item_id}` → `{pet, tx, bag_item, growth_event, reaction_text}`
- 内部：★`POST /rewards/consume-events {course_id?}` → `{consumed, awarded:[{event_id, points}]}`（手动触发；后台线程每 30s 自动消费）。结算规则：`practice_graded 且 passed` → +5（每日上限 50）；`task_criteria_met` → +20 并将关联 practice 任务置 done。

### A7 speech
- ★`POST /speech/tts {text, voice?, cache_key?}` → `{audio_id, url, cache_hit, duration_ms}`；★`POST /speech/tts/batch {segments:[{segment_id,text}], voice?}` → `{items:[{segment_id, audio_id, url, cache_hit}]}`
- ★`GET /speech/audio/{audio_id}` → WAV 字节（`audio/wav`）
- ★`POST /speech/asr`（multipart `file`）→ `{transcript, confidence}`
- ★`GET /speech/oral/scenes`；★`POST /speech/oral/sessions {scene_id, course_id?}` → `{session, opening:{text, audio_id}}`
- ★`POST /speech/oral/sessions/{session_id}/turn {transcript?|file?}` → `{turn, finished:bool}`；★`POST /speech/oral/sessions/{session_id}/finish` → `{summary:{turns, total_seconds, tips:[string]}}`
- 引擎经 `ZHI_TTS_PROVIDER=mock|echo`、`ZHI_ASR_PROVIDER=mock` 可插拔；默认 mock 生成可播放 WAV（正弦提示音+静音，时长按文本长度估算）；TTS 失败返回 500 结构，前端须可降级。

### A8 notifications
- ★`GET /notifications?unread_only=&cursor=`；★`POST /notifications/{ntf_id}/read`；★`POST /notifications/read-all`
- ★`GET/PATCH /notifications/settings`
- 内部：`POST /notifications/generate {date}`（DDL 前 `ddl_remind_hours` 提醒今日任务/到期 DDL、乙侧到期复习；同 ref 同日去重；免打扰与 max_per_day 限频）

### B 契约桩 mock_b（数据来自 `contracts/fixtures/`；行为与乙实现一致）
- ★`GET /materials?course_id=`；★`POST /materials {course_id, filename}`（multipart）→ `{material, job_id}`；★`GET /materials/{material_id}`
- ★`GET /courses/{course_id}/graph` → `{nodes, edges}`；★`GET /graph/nodes/{node_id}`；★`GET /graph/nodes/{node_id}/sources`
- ★`POST /tutoring/ask {course_id, question, concept_id?, mode:"explain|socratic|hint", hint_level?}` → `{answer_id, text, mode, hint_level, source_refs:[source_ref], next_hint_available}`
- ★`GET /lessons?course_id=` → `{items:[{lesson_id,title,page_count,published_at}]}`；★`GET /lessons/{lesson_id}` → 1.6 结构
- ★`GET /lessons/{lesson_id}/quiz` → `{items:[question]}`；question：`{question_id, concept_ids, type:"single|blank|solve", stem, options?, answer_hint_available:true}`
- ★`POST /attempts {question_id, course_id, answer, hints_used?, source_task_id?}` → attempt（桩按 fixtures 判分并生成证据）；★`GET /attempts/{attempt_id}`
- ★`POST /exams/import {course_id, material_id}` → exam+job；★`GET /exams/{exam_id}`；★`PATCH /exams/{exam_id}/blueprint {blueprint}`；★`POST /exams/{exam_id}/generate` → `{job_id}`；★`GET /exams/{exam_id}/paper` → `{questions:[question]}`；★`POST /exams/{exam_id}/submit {answers:[{question_id,answer}]}` → `{summary:{score,total_score,graded_at,concept_scores:[{concept_id,score,max_score}]}}`；★`GET /exams/{exam_id}/export` → `{format:"pdf", url}`
- ★`POST /mistakes/capture`（multipart image + course_id）→ `{job_id, mistake_id}`；★`GET /mistakes?course_id=&concept_id=&q=`；★`GET /mistakes/{mistake_id}`；★`POST /mistakes/{mistake_id}/variants/{variant_id}/attempts {answer, source_task_id?}` → attempt
- ★`GET /courses/{course_id}/learning-snapshot` → `{snapshot_version, generated_at, concepts:[{concept_id,name,mastery,evidence_count,updated_at}], recommended_items:[recommended_item], due_reviews:[review_item]}`
- ★`GET /reviews/due?course_id=&date=` → `{items:[review_item]}`；★`POST /reviews/{review_item_id}/grade {quality}` → review_item
- ★`GET /learning-events?cursor=&course_id=&limit=` → 1.5
- ★`GET /jobs/{job_id}`；★`POST /jobs/{job_id}/retry`
- 桩的 job 模拟：创建时 `running`，每查询一步推进 progress，第 3 次查询转 `succeeded` 并回填 result_ref（前端展示进度用；可重试）。

## 3 fixtures 基线（`contracts/fixtures/`，S1 创建，F 侧 Fake 同数据）

`course.json`（1 样例课程 2 成员）、`users.json`（demo/alt 两用户）、`materials.json`（1 份 24 页一模卷，含 3 章 40 个 block）、`graph.json`（12 节点 14 边含 prerequisite 无环）、`lessons.json`（1 课 3 页，每页 ≥2 elements ≥3 讲解段）、`questions.json`（6 题：3 单选 2 填空 1 解答，含标准答案与判分依据模板）、`attempts.json`（4 条历史作答）、`exams.json`（1 卷蓝图）、`mistakes.json`（2 道错题含分步讲解与 2 变式）、`snapshot.json`（12 概念掌握度、5 条 recommended_items）、`events.json`（6 条事件：2 submitted、3 graded、1 task_criteria_met）、`reviews.json`（3 条到期复习）、`scenes.json`（3 个口语场景）。
所有 fixture ID 固定可预期（如 `con_triangle_1`），保证前端 Fake 与后端桩返回一致。
