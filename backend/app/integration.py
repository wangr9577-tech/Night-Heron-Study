"""A's in-process adapter to the real B engine. A alone writes tasks and rewards."""

import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import HTTPException
from fastapi.exceptions import RequestValidationError

from backend.engine.access import Identity
from backend.engine.config import Settings
from backend.engine.errors import DomainError
from backend.registration import register_modules
from backend.review.router import events, learning_snapshot

from . import core


class AppAccess:
    def authenticate(self, token):
        try:
            user = core.current_user("Bearer " + token)
        except HTTPException as exc:
            raise DomainError("UNAUTHENTICATED", "登录已失效，请重新登录", 401) from exc
        with core.db() as c:
            courses = tuple(
                r["course_id"] for r in c.execute("SELECT course_id FROM members WHERE user_id=?", (user,))
            )
        # Learning accounts cannot grant themselves teacher/reviewer permissions.
        return Identity(user, courses)

    def require_course_access(self, user, course):
        try:
            with core.db() as c:
                core.require_course(c, user, course)
                row = c.execute("SELECT data FROM courses WHERE course_id=?", (course,)).fetchone()
                if not row or json.loads(row["data"]).get("archived"):
                    raise HTTPException(403, "课程已归档或无访问权限")
        except HTTPException as exc:
            raise DomainError("COURSE_FORBIDDEN", str(exc.detail), exc.status_code) from exc

    def require_permission(self, user, course, permission):
        """Only a server-side, course-specific grant permits content review."""
        self.require_course_access(user, course)
        with core.db() as c:
            grant = c.execute(
                "SELECT 1 FROM review_permissions WHERE user_id=? AND course_id=? AND permission=?",
                (user, course, permission),
            ).fetchone()
        if not grant:
            raise DomainError("PERMISSION_REQUIRED", "需要该课程的内容审核权限", 403)


def engine():
    from .main import app

    return app.state.learning_engine


def install(app):
    a_validation = app.exception_handlers.get(RequestValidationError)
    learning = register_modules(
        app,
        Settings(
            data_dir=Path(os.getenv("ZHUOZHI_DATA_DIR", core.DB_PATH.parent / "learning")).resolve(),
            mode="integrated",
        ),
        AppAccess(),
    )
    b_validation = app.exception_handlers[RequestValidationError]

    @app.exception_handler(RequestValidationError)
    async def validation(request, exc):
        endpoint = getattr(request.scope.get("route"), "endpoint", None)
        handler = (
            a_validation if getattr(endpoint, "__module__", "").startswith("backend.app.") else b_validation
        )
        return await handler(request, exc)

    app.router.add_event_handler("startup", learning.start)
    app.router.add_event_handler("shutdown", learning.close)
    with core.db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS task_evidence (
            task_id TEXT NOT NULL, attempt_id TEXT NOT NULL, question_id TEXT NOT NULL,
            PRIMARY KEY(task_id,attempt_id));
        CREATE TABLE IF NOT EXISTS app_commands (
            user_id TEXT NOT NULL, command_key TEXT NOT NULL, request_hash TEXT NOT NULL,
            result TEXT NOT NULL, PRIMARY KEY(user_id,command_key));
        """)
    return learning


def snapshot(user, course):
    service = engine()
    service.access.require_course_access(user, course)
    return learning_snapshot(ctx=(user, course), engine=service)


def candidates(user, course):
    service = engine()
    state = snapshot(user, course)
    with service.db.connect() as c:
        questions = service.db.list(c, user, course, "question")
        concepts = {x["id"]: x for x in service.db.list(c, user, course, "concept")}
        result = []
        used = set()
        for item in state["candidates"]:
            if item["type"] == "review":
                review = service.db.get(c, user, course, "review", item["target_id"])
                q = service.db.get(c, user, course, "question", review["question_id"])
                result.append(dict(item, title="间隔复习：" + q["prompt"], question_id=q["id"]))
            elif item["type"] == "concept":
                for q in questions:
                    if item["target_id"] in q["concept_ids"] and q["id"] not in used:
                        used.add(q["id"])
                        result.append(
                            dict(
                                item,
                                candidate_id="question:" + q["id"],
                                type="practice",
                                target_id=q["id"],
                                title=q["prompt"],
                                estimated_minutes=10,
                                concept_title=concepts[item["target_id"]]["title"],
                            )
                        )
        return result


def locate(user, kind, key):
    service = engine()
    with service.db.connect() as c:
        row = c.execute(
            "SELECT course_id FROM b_entities WHERE id=? AND user_id=? AND kind=?", (key, user, kind)
        ).fetchone()
        if not row:
            raise HTTPException(404, "对象不存在或无访问权限")
        course = row["course_id"]
        service.access.require_course_access(user, course)
        return course, service.db.get(c, user, course, kind, key)


def consume(user, course=None):
    """Read B's trusted event query, then atomically checkpoint A's task/ledger writes."""
    from .extra import balance, transaction

    service = engine()
    scope = course or ""
    if course:
        service.access.require_course_access(user, course)
    for _ in range(5):
        with core.db() as c:
            row = c.execute(
                "SELECT cursor FROM event_cursors WHERE user_id=? AND course_scope=?", (user, scope)
            ).fetchone()
            cursor = row["cursor"] if row and row["cursor"] else "0"
        page = events(cursor=cursor, limit=200, actor=Identity(user, ()), engine=service)
        with core.db() as c:
            c.execute("BEGIN IMMEDIATE")
            row = c.execute(
                "SELECT cursor FROM event_cursors WHERE user_id=? AND course_scope=?", (user, scope)
            ).fetchone()
            actual = row["cursor"] if row and row["cursor"] else "0"
            if actual != cursor:
                continue
            awarded, count = [], 0
            for event in page["items"]:
                cid = event["course_id"]
                if course and cid != course:
                    continue
                service.access.require_course_access(user, cid)
                if c.execute(
                    "SELECT 1 FROM consumed_events WHERE event_id=?", (event["event_id"],)
                ).fetchone():
                    continue
                result = event["result"]
                amount = 0
                qualified = (
                    event["event_type"] == "practice_graded"
                    and result.get("score", 0) >= 0.7
                    and result.get("evidence_weight", 0) > 0
                )
                if qualified:
                    local_day = datetime.now(timezone(timedelta(hours=8))).date().isoformat()
                    earned = c.execute(
                        "SELECT COALESCE(SUM(amount),0) FROM transactions WHERE user_id=? AND reason='practice_graded' AND substr(datetime(at,'+8 hours'),1,10)=?",
                        (user, local_day),
                    ).fetchone()[0]
                    amount = max(0, min(5, 50 - earned))
                task_id = event.get("source_task_id")
                row = (
                    c.execute(
                        "SELECT data FROM tasks WHERE task_id=? AND user_id=? AND course_id=?",
                        (task_id, user, cid),
                    ).fetchone()
                    if task_id
                    else None
                )
                if row and event["event_type"] in ("practice_graded", "review_completed"):
                    task = json.loads(row["data"])
                    with service.db.connect() as b:
                        attempt = service.db.get(b, user, cid, "attempt", result["attempt_id"])
                        qid = attempt["question_id"]
                        matched = task["type"] == "practice" and task["target_id"] == qid
                        if task["type"] == "mistake":
                            mistake = service.db.get(b, user, cid, "mistake", task["target_id"])
                            matched = qid in mistake["variant_ids"]
                        if task["type"] == "exam":
                            exam = service.db.get(b, user, cid, "exam", task["target_id"])
                            expected = {i["question_id"] for i in exam["items"]}
                            matched = attempt.get("exam_id") == task["target_id"] and qid in expected
                        if task["type"] == "review":
                            matched = (
                                event["event_type"] == "review_completed"
                                and result.get("review_id") == task["target_id"]
                                and attempt.get("review_id") == task["target_id"]
                            )
                            qualified = (
                                matched
                                and attempt.get("score", 0) >= 0.7
                                and attempt.get("evidence_weight", 0) > 0
                            )
                        if (
                            matched
                            and qualified
                            and attempt.get("source_task_id") == task_id
                            and task["status"] not in ("done", "cancelled")
                        ):
                            c.execute(
                                "INSERT OR IGNORE INTO task_evidence VALUES (?,?,?)",
                                (task_id, attempt["id"], qid),
                            )
                            seen = {
                                r["question_id"]
                                for r in c.execute(
                                    "SELECT question_id FROM task_evidence WHERE task_id=?", (task_id,)
                                )
                            }
                            if task["type"] != "exam" or expected <= seen:
                                task.update(status="done", completed_at=core.now(), progress_percent=100)
                                c.execute(
                                    "UPDATE tasks SET data=? WHERE task_id=? AND user_id=?",
                                    (json.dumps(task, ensure_ascii=False), task_id, user),
                                )
                                transaction(c, user, "earn", 20, "task_criteria_met", "task", task_id)
                                awarded.append(dict(event_id=event["event_id"], points=20, task_id=task_id))
                if amount:
                    transaction(c, user, "earn", amount, "practice_graded", "event", event["event_id"])
                    awarded.append(dict(event_id=event["event_id"], points=amount))
                c.execute("INSERT INTO consumed_events VALUES (?,?,?)", (event["event_id"], user, core.now()))
                count += 1
            c.execute(
                "INSERT INTO event_cursors VALUES (?,?,?,?) ON CONFLICT(user_id,course_scope) DO UPDATE SET cursor=excluded.cursor,updated_at=excluded.updated_at",
                (user, scope, page["next_cursor"], core.now()),
            )
            return dict(consumed=count, awarded=awarded, has_more=page["has_more"], balance=balance(c, user))
    raise HTTPException(409, "学习成果正在同步，请重试")
