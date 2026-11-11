import datetime as dt
import json
import secrets
from typing import Any

from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator, model_validator

from .core import current_user, db, init_core, new_id, now, password_hash, require_course

init_core()
app = FastAPI(title="啄知 AI")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
router = APIRouter(prefix="/api/v1")


@app.exception_handler(HTTPException)
async def http_error(request: Request, exc: HTTPException):
    codes = {
        400: "invalid_request",
        401: "unauthorized",
        403: "no_course_access",
        404: "not_found",
        409: "conflict",
        422: "business_rule",
    }
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error_code": codes.get(exc.status_code, "internal"),
            "message": str(exc.detail),
            "detail": None,
        },
    )


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=400, content={"error_code": "invalid_request", "message": "请求参数无效", "detail": None}
    )


class Credentials(BaseModel):
    username: str = Field(min_length=1, max_length=80)
    password: str = Field(min_length=6, max_length=200)
    nickname: str | None = None


def decode(row):
    return json.loads(row["data"])


def save(con, table, key, value):
    assert table in ("users", "courses", "tasks")
    pk = {"users": "user_id", "courses": "course_id", "tasks": "task_id"}[table]
    con.execute(f"UPDATE {table} SET data=? WHERE {pk}=?", (json.dumps(value, ensure_ascii=False), key))


def session(con, uid):
    token = secrets.token_urlsafe(32)
    con.execute("INSERT INTO sessions VALUES (?,?)", (token, uid))
    return token


@app.get("/healthz")
def health():
    return {"ok": True}


@router.post("/auth/register")
def register(body: Credentials):
    with db() as con:
        if con.execute("SELECT 1 FROM users WHERE username=?", (body.username,)).fetchone():
            raise HTTPException(409, "用户名已存在")
        uid = new_id("usr")
        user = {
            "user_id": uid,
            "username": body.username,
            "nickname": body.nickname or body.username,
            "avatar_key": "bird_1",
            "settings": {},
            "created_at": now(),
        }
        con.execute(
            "INSERT INTO users VALUES (?,?,?,?)",
            (uid, body.username, password_hash(body.password), json.dumps(user, ensure_ascii=False)),
        )
        return {"user": user, "access_token": session(con, uid)}


@router.post("/auth/login")
def login(body: Credentials):
    with db() as con:
        row = con.execute("SELECT * FROM users WHERE username=?", (body.username,)).fetchone()
        if not row or not secrets.compare_digest(
            row["password"], password_hash(body.password, row["password"].split("$")[0])
        ):
            raise HTTPException(401, "用户名或密码错误")
        return {"user": decode(row), "access_token": session(con, row["user_id"])}


@router.post("/auth/logout")
def logout(user: str = Depends(current_user), authorization: str = Header()):
    with db() as con:
        con.execute("DELETE FROM sessions WHERE token=?", (authorization[7:],))
    return {"ok": True}


@router.get("/users/me")
def me(user: str = Depends(current_user)):
    with db() as con:
        return decode(con.execute("SELECT data FROM users WHERE user_id=?", (user,)).fetchone())


@router.patch("/users/me")
def update_me(body: dict[str, Any], user: str = Depends(current_user)):
    with db() as con:
        value = decode(con.execute("SELECT data FROM users WHERE user_id=?", (user,)).fetchone())
        value.update({k: v for k, v in body.items() if k in ("nickname", "avatar_key", "settings")})
        save(con, "users", user, value)
        return value


@router.get("/courses")
def courses(user: str = Depends(current_user)):
    with db() as con:
        rows = con.execute(
            "SELECT c.data,m.role FROM courses c JOIN members m ON c.course_id=m.course_id WHERE m.user_id=?",
            (user,),
        ).fetchall()
        return {"items": [{**decode(r), "role": r["role"]} for r in rows]}


class AvailableSlot(BaseModel):
    weekday: int = Field(ge=1, le=7, strict=True)
    start: str
    end: str

    @field_validator("start", "end")
    @classmethod
    def valid_time(cls, value):
        import re

        if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", value):
            raise ValueError("time must be HH:MM")
        return value

    @model_validator(mode="after")
    def valid_range(self):
        if self.end <= self.start:
            raise ValueError("end must follow start")
        return self


class CourseInput(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    subject: str = ""
    goal_text: str = ""
    ddl: dt.date | None = None
    available_slots: list[AvailableSlot] = Field(default_factory=list)

    @field_validator("ddl", mode="before")
    @classmethod
    def valid_ddl(cls, value):
        if value is not None and not isinstance(value, (str, dt.date)):
            raise ValueError("ddl must be an ISO date")
        return value


class CoursePatch(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    subject: str | None = None
    goal_text: str | None = None
    ddl: dt.date | None = None
    available_slots: list[AvailableSlot] | None = None

    @field_validator("ddl", mode="before")
    @classmethod
    def valid_ddl(cls, value):
        if value is not None and not isinstance(value, (str, dt.date)):
            raise ValueError("ddl must be an ISO date")
        return value


@router.post("/courses")
def create_course(body: CourseInput, user: str = Depends(current_user)):
    cid = new_id("crs")
    stamp = now()
    value = {
        **body.model_dump(mode="json"),
        "course_id": cid,
        "owner_user_id": user,
        "role": "owner",
        "archived": False,
        "created_at": stamp,
        "updated_at": stamp,
    }
    with db() as con:
        con.execute("INSERT INTO courses VALUES (?,?,?)", (cid, user, json.dumps(value, ensure_ascii=False)))
        con.execute("INSERT INTO members VALUES (?,?,?)", (cid, user, "owner"))
    return value


@router.get("/courses/{course_id}")
def get_course(course_id: str, user: str = Depends(current_user)):
    with db() as con:
        role = require_course(con, user, course_id)
        return {
            **decode(con.execute("SELECT data FROM courses WHERE course_id=?", (course_id,)).fetchone()),
            "role": role,
        }


@router.patch("/courses/{course_id}")
def patch_course(course_id: str, body: CoursePatch, user: str = Depends(current_user)):
    with db() as con:
        if require_course(con, user, course_id) != "owner":
            raise HTTPException(403, "仅课程拥有者可修改")
        value = decode(con.execute("SELECT data FROM courses WHERE course_id=?", (course_id,)).fetchone())
        changes = body.model_dump(mode="json", exclude_unset=True)
        if any(
            changes.get(k, "present") is None for k in ("title", "subject", "goal_text", "available_slots")
        ):
            raise HTTPException(400, "字段不能为 null")
        value.update(changes)
        value["updated_at"] = now()
        save(con, "courses", course_id, value)
        if {'ddl','available_slots'} & changes.keys():
            from .planning import replan_pending
            return dict(value,replan=replan_pending(con,value,user))
        return value


@router.post("/courses/{course_id}/archive")
def archive(course_id: str, user: str = Depends(current_user)):
    with db() as con:
        if require_course(con, user, course_id) != "owner":
            raise HTTPException(403, "仅课程拥有者可归档")
        value = decode(con.execute("SELECT data FROM courses WHERE course_id=?", (course_id,)).fetchone())
        value["archived"] = True
        value["updated_at"] = now()
        save(con, "courses", course_id, value)
        return value


@router.get("/courses/{course_id}/members")
def members(course_id: str, user: str = Depends(current_user)):
    with db() as con:
        require_course(con, user, course_id)
        rows = con.execute("SELECT user_id,role FROM members WHERE course_id=?", (course_id,)).fetchall()
        return {"items": [dict(r) for r in rows]}


@router.post("/courses/{course_id}/members")
def add_member(course_id: str, body: dict[str, Any], user: str = Depends(current_user)):
    with db() as con:
        if require_course(con, user, course_id) != "owner":
            raise HTTPException(403, "仅课程拥有者可添加成员")
        uid = body.get("user_id")
        if not con.execute("SELECT 1 FROM users WHERE user_id=?", (uid,)).fetchone():
            raise HTTPException(404, "用户不存在")
        if con.execute("SELECT 1 FROM members WHERE course_id=? AND user_id=?", (course_id, uid)).fetchone():
            raise HTTPException(409, "成员已存在")
        con.execute("INSERT INTO members VALUES (?,?,?)", (course_id, uid, "member"))
        return {"user_id": uid, "role": "member"}


@router.delete("/courses/{course_id}/members/{member_id}")
def remove_member(course_id: str, member_id: str, user: str = Depends(current_user)):
    with db() as con:
        if require_course(con, user, course_id) != "owner":
            raise HTTPException(403, "仅课程拥有者可移除成员")
        if member_id == user:
            raise HTTPException(422, "不可移除课程拥有者")
        con.execute("DELETE FROM members WHERE course_id=? AND user_id=?", (course_id, member_id))
        return {"ok": True}


class TaskInput(BaseModel):
    type: str
    target_id: str
    title: str = Field(min_length=1)
    planned_date: dt.date
    planned_time_slot: str | None = None
    estimated_minutes: int = Field(default=30, ge=1, le=1440)


def get_task(con, task_id, user):
    row = con.execute("SELECT * FROM tasks WHERE task_id=? AND user_id=?", (task_id, user)).fetchone()
    if not row:
        raise HTTPException(404, "任务不存在")
    require_course(con, user, row["course_id"])
    return decode(row)


def task_list(con, course_id, user):
    require_course(con, user, course_id)
    return [
        decode(r)
        for r in con.execute("SELECT data FROM tasks WHERE course_id=? AND user_id=?", (course_id, user))
    ]


@router.post("/courses/{course_id}/planner/tasks")
def create_task(course_id: str, body: TaskInput, user: str = Depends(current_user)):
    if body.type not in ("lesson", "practice", "exam", "mistake", "review", "qa"):
        raise HTTPException(400, "未知任务类型")
    value = {
        **body.model_dump(mode="json"),
        "task_id": new_id("tsk"),
        "course_id": course_id,
        "status": "pending",
        "reason": "",
        "source": "manual",
        "candidate_id": None,
        "suggested_due_at": None,
        "completed_at": None,
        "progress_percent": None,
        "reschedule_history": [],
    }
    with db() as con:
        require_course(con, user, course_id)
        con.execute(
            "INSERT INTO tasks VALUES (?,?,?,?)",
            (value["task_id"], course_id, user, json.dumps(value, ensure_ascii=False)),
        )
    return value


@router.get("/courses/{course_id}/planner/today")
def today(course_id: str, date: dt.date | None = None, user: str = Depends(current_user)):
    local_tz = dt.timezone(dt.timedelta(hours=8))
    requested_day = date or dt.datetime.now(local_tz).date()
    day = str(requested_day)
    start = dt.datetime.combine(requested_day, dt.time.min, local_tz).astimezone(dt.timezone.utc)
    end = start + dt.timedelta(days=1)
    with db() as con:
        items = [
            t
            for t in task_list(con, course_id, user)
            if t["planned_date"] == day and t["status"] != "cancelled"
        ]
        points = con.execute(
            "SELECT COALESCE(SUM(amount),0) FROM transactions WHERE user_id=? AND type='earn' AND at>=? AND at<?",
            (
                user,
                start.isoformat(timespec="seconds").replace("+00:00", "Z"),
                end.isoformat(timespec="seconds").replace("+00:00", "Z"),
            ),
        ).fetchone()[0]
    return {
        "date": day,
        "items": items,
        "summary": {
            "total": len(items),
            "done": sum(t["status"] == "done" for t in items),
            "points_today": points,
        },
    }


@router.get("/courses/{course_id}/planner/calendar")
def calendar(course_id: str, month: str, user: str = Depends(current_user)):
    try:
        dt.date.fromisoformat(month + "-01")
    except ValueError:
        raise HTTPException(400, "月份格式应为 YYYY-MM") from None
    with db() as con:
        items = [
            t
            for t in task_list(con, course_id, user)
            if t["planned_date"].startswith(month) and t["status"] != "cancelled"
        ]
    return {
        "month": month,
        "days": [
            {"date": d, "items": [t for t in items if t["planned_date"] == d]}
            for d in sorted({t["planned_date"] for t in items})
        ],
    }


@router.get("/courses/{course_id}/planner/completions")
def completions(course_id: str, month: str = "", user: str = Depends(current_user)):
    with db() as con:
        items = task_list(con, course_id, user)
    return {
        "items": [
            {
                "task_id": t["task_id"],
                "title": t["title"],
                "completed_at": t["completed_at"],
                "points_awarded": None,
            }
            for t in items
            if t["completed_at"] and t["completed_at"].startswith(month)
        ],
        "points_attribution_available": False,
    }


@router.get("/planner/tasks/{task_id}")
def task_detail(task_id: str, user: str = Depends(current_user)):
    with db() as con:
        return get_task(con, task_id, user)


@router.get("/planner/tasks/{task_id}/route")
def task_route(task_id: str, user: str = Depends(current_user)):
    with db() as con:
        task = get_task(con, task_id, user)
    paths = {
        "lesson": "lesson",
        "practice": "practice",
        "exam": "exam",
        "mistake": "mistakes",
        "review": "review",
        "qa": "tutoring",
    }
    path = paths[task["type"]]
    return {
        "type": task["type"],
        "target_id": task["target_id"],
        "course_id": task["course_id"],
        "route": f"/course/{task['course_id']}/{path}"
        + ("" if path in ("review", "tutoring") else "/" + task["target_id"]),
    }


@router.post("/planner/tasks/{task_id}/complete")
def complete(task_id: str, body: dict[str, Any], user: str = Depends(current_user)):
    with db() as con:
        task = get_task(con, task_id, user)
        if task["type"] in ("practice", "exam", "mistake", "review") and body.get('completion') == 'full':
            raise HTTPException(422, "该任务须由学习结果确认完成")
        if task["status"] in ("done", "cancelled"):
            raise HTTPException(422, "当前任务不能完成")
        if body.get("completion") not in ("full", "partial"):
            raise HTTPException(400, "完成类型无效")
        progress = body.get("progress_percent")
        if progress is not None and (not isinstance(progress, (int, float)) or not 0 <= progress <= 100):
            raise HTTPException(400, "进度无效")
        task["status"] = "done" if body["completion"] == "full" else "partial"
        task["completed_at"] = now() if task["status"] == "done" else None
        task["progress_percent"] = 100 if task["status"] == "done" else progress
        save(con, "tasks", task_id, task)
        return task


@router.post("/planner/tasks/{task_id}/reschedule")
def reschedule(task_id: str, body: dict[str, Any], user: str = Depends(current_user)):
    try:
        date = str(dt.date.fromisoformat(body["to_date"]))
    except (KeyError, TypeError, ValueError):
        raise HTTPException(400, "日期无效") from None
    with db() as con:
        task = get_task(con, task_id, user)
        if task["status"] in ("done", "cancelled"):
            raise HTTPException(422, "当前任务不能调整")
        task["reschedule_history"].append(
            {
                "from_date": task["planned_date"],
                "to_date": date,
                "reason": body.get("reason", "manual"),
                "at": now(),
            }
        )
        task["planned_date"] = date
        task["planned_time_slot"] = body.get("to_slot")
        task["status"] = "postponed"
        save(con, "tasks", task_id, task)
        return task


@router.post("/planner/tasks/{task_id}/pin")
def pin(task_id: str, body: dict[str, Any], user: str = Depends(current_user)):
    with db() as con:
        task = get_task(con, task_id, user)
        if task["status"] in ("done", "cancelled"):
            raise HTTPException(422, "当前任务不能固定")
        if body.get("date"):
            try:
                task["planned_date"] = str(dt.date.fromisoformat(body["date"]))
            except (TypeError, ValueError):
                raise HTTPException(400, "日期无效") from None
        task["status"] = "pinned" if body.get("date") else "pending"
        save(con, "tasks", task_id, task)
        return task


@router.post("/planner/tasks/{task_id}/cancel")
def cancel(task_id: str, user: str = Depends(current_user)):
    with db() as con:
        task = get_task(con, task_id, user)
        if task["status"] == "done":
            raise HTTPException(422, "已完成任务不能取消")
        task["status"] = "cancelled"
        save(con, "tasks", task_id, task)
        return task


def demo_candidates(course_id):
    return [
        {
            "candidate_id": "cand_demo_lesson",
            "type": "lesson",
            "target_id": f"les_demo_{course_id}",
            "title": "示例：复习函数基础",
            "estimated_minutes": 25,
            "reason": "演示推荐，供排程联调",
            "suggested_due_at": None,
        },
        {
            "candidate_id": "cand_demo_practice",
            "type": "practice",
            "target_id": f"qst_demo_{course_id}",
            "title": "示例：函数基础练习",
            "estimated_minutes": 20,
            "reason": "演示推荐，供排程联调",
            "suggested_due_at": None,
        },
    ]


def demo_snapshot(course_id: str, user: str = Depends(current_user)):
    with db() as con:
        require_course(con, user, course_id)
    return {
        "snapshot_version": "demo-1",
        "generated_at": now(),
        "concepts": [],
        "recommended_items": demo_candidates(course_id),
        "due_reviews": [],
        "is_demo": True,
    }


def demo_events(
    course_id: str | None = None,
    cursor: str | None = None,
    limit: int = 50,
    user: str = Depends(current_user),
):
    if course_id:
        with db() as con:
            require_course(con, user, course_id)
    return {"events": [], "next_cursor": None, "is_demo": True}


@router.get("/courses/{course_id}/planner/candidates")
def candidates(course_id: str, user: str = Depends(current_user)):
    from .integration import candidates as real_candidates
    from .integration import snapshot

    state = snapshot(user, course_id)
    return {
        "items": real_candidates(user, course_id),
        "snapshot_version": str(state["state_version"]),
        "generated_at": state["generated_at"],
    }


def add_candidate(con, course_id, user, candidate, day, slot=None):
    all_tasks = task_list(con, course_id, user)
    if any(t["candidate_id"] == candidate["candidate_id"] and t["status"] != "cancelled" for t in all_tasks):
        raise HTTPException(409, "该推荐已有任务")
    value = {
        "task_id": new_id("tsk"),
        "course_id": course_id,
        "type": candidate["type"],
        "target_id": candidate["target_id"],
        "title": candidate["title"],
        "status": "pending",
        "planned_date": str(day),
        "planned_time_slot": slot,
        "estimated_minutes": candidate["estimated_minutes"],
        "reason": candidate["reason"],
        "source": "recommended",
        "candidate_id": candidate["candidate_id"],
        "suggested_due_at": candidate["suggested_due_at"],
        "completed_at": None,
        "progress_percent": None,
        "reschedule_history": [],
    }
    con.execute(
        "INSERT INTO tasks VALUES (?,?,?,?)",
        (value["task_id"], course_id, user, json.dumps(value, ensure_ascii=False)),
    )
    return value


@router.post("/courses/{course_id}/planner/accept-recommendation")
def accept_recommendation(course_id: str, body: dict[str, Any], user: str = Depends(current_user)):
    from .integration import candidates as real_candidates

    candidate = next(
        (c for c in real_candidates(user, course_id) if c["candidate_id"] == body.get("candidate_id")), None
    )
    if not candidate:
        raise HTTPException(404, "推荐不存在")
    try:
        date = dt.date.fromisoformat(body.get("planned_date") or str(dt.date.today()))
    except (ValueError, TypeError):
        raise HTTPException(400, "日期无效") from None
    with db() as con:
        require_course(con, user, course_id)
        return add_candidate(con, course_id, user, candidate, date, body.get("planned_time_slot"))


@router.post("/courses/{course_id}/planner/auto-generate")
def auto_generate(course_id: str, body: dict[str, Any], user: str = Depends(current_user)):
    try:
        date = dt.date.fromisoformat(body["date"])
    except (KeyError, ValueError, TypeError):
        raise HTTPException(400, "日期无效") from None
    from .integration import candidates as real_candidates

    recommendations = real_candidates(user, course_id)
    items = []
    skipped = []
    with db() as con:
        con.execute("BEGIN IMMEDIATE")
        require_course(con, user, course_id)
        course = decode(con.execute("SELECT data FROM courses WHERE course_id=?", (course_id,)).fetchone())
        slots = [s for s in course.get("available_slots", []) if s.get("weekday") == date.isoweekday()]
        if not slots:
            return {
                "items": [],
                "skipped": [
                    {"candidate_id": c["candidate_id"], "reason": "当天没有可用时段"} for c in recommendations
                ],
            }
        if course.get("ddl") and str(date) > course["ddl"]:
            return {
                "items": [],
                "skipped": [
                    {"candidate_id": c["candidate_id"], "reason": "已超过课程截止日期"}
                    for c in recommendations
                ],
            }
        ranges = []
        for s in slots:
            try:
                start = dt.datetime.combine(date, dt.time.fromisoformat(s["start"]))
                end = dt.datetime.combine(date, dt.time.fromisoformat(s["end"]))
                if end > start:
                    ranges.append([start, end])
            except (ValueError, KeyError, TypeError):
                continue
        existing = task_list(con, course_id, user)
        for c in recommendations:
            if any(t["candidate_id"] == c["candidate_id"] and t["status"] != "cancelled" for t in existing):
                skipped.append({"candidate_id": c["candidate_id"], "reason": "已有任务"})
                continue
            duration = dt.timedelta(minutes=c["estimated_minutes"])
            placed = False
            for slot in ranges:
                while slot[0] + duration <= slot[1]:
                    start = slot[0]
                    end = start + duration
                    busy = []
                    for t in existing:
                        if (
                            t["planned_date"] != str(date)
                            or t["status"] == "cancelled"
                            or not t.get("planned_time_slot")
                        ):
                            continue
                        try:
                            ts = dt.datetime.combine(date, dt.time.fromisoformat(t["planned_time_slot"]))
                            te = ts + dt.timedelta(minutes=t["estimated_minutes"])
                            if start < te and end > ts:
                                busy.append(te)
                        except ValueError:
                            continue
                    if busy:
                        slot[0] = max(busy)
                        continue
                    task = add_candidate(con, course_id, user, c, date, start.strftime("%H:%M"))
                    items.append(task)
                    existing.append(task)
                    slot[0] = end
                    placed = True
                    break
                if placed:
                    break
            if not placed:
                skipped.append({"candidate_id": c["candidate_id"], "reason": "可用时段不足"})
    return {"items": items, "skipped": skipped}


app.include_router(router)

try:
    from .extra import init_extra, start_notification_scheduler
    from .extra import router as extra_router

    init_extra()
    app.include_router(extra_router)
    start_notification_scheduler(app)
except ImportError as exc:
    if exc.name != "app.extra":
        raise

from .integration import install  # noqa: E402 - A tables and routes must be initialized before these adapters.
from .learning import router as learning_router  # noqa: E402 - A tables and routes must be initialized before these adapters.
from .pet_sprites import router as pet_sprites_router  # noqa: E402 - A tables and routes must be initialized before these adapters.

install(app)
app.include_router(learning_router)
app.include_router(pet_sprites_router)
