from fastapi import APIRouter, Depends, Query

from backend.engine.context import course_context, get_engine, identity
from backend.engine.db import now
from backend.engine.errors import DomainError, require
from contracts.models import EventPage, LearningSnapshot, ReviewRate

from .service import rate, snapshot

router = APIRouter(tags=["B8 间隔复习、学习快照与成果事件"])


@router.get("/api/v1/courses/{course_id}/reviews")
def reviews(due_only: bool = True, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        data = engine.db.list(c, *ctx, "review")
        return {
            "items": sorted(
                [r for r in data if not due_only or r["suggested_due_at"] <= now()],
                key=lambda r: r["suggested_due_at"],
            )
        }


@router.get("/api/v1/courses/{course_id}/reviews/{review_id}")
def review_get(review_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return engine.db.get(c, *ctx, "review", review_id)


@router.post("/api/v1/courses/{course_id}/reviews/{review_id}/rate")
def review_rate(review_id: str, body: ReviewRate, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        return rate(engine, c, *ctx, review_id, body)


@router.get("/api/v1/courses/{course_id}/learning-snapshot", response_model=LearningSnapshot)
def learning_snapshot(ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return snapshot(engine, c, *ctx)


@router.get("/api/v1/learning-events", response_model=EventPage)
def events(
    cursor: str = "0",
    limit: int = Query(default=50, ge=1, le=200),
    actor=Depends(identity),
    engine=Depends(get_engine),
):
    import json

    # Cursor is an opaque monotone sequence position, never an authority to read another user.
    require(
        cursor.isascii() and cursor.isdecimal() and len(cursor) <= 18,
        "INVALID_CURSOR",
        "游标必须为有效的非负序号",
        422,
    )
    position = int(cursor)
    with engine.db.connect() as c:
        rows = c.execute(
            "SELECT * FROM b_events WHERE user_id=? AND seq>? ORDER BY seq LIMIT ?",
            (actor.user_id, position, limit + 1),
        ).fetchall()
        items, last = [], position
        for row in rows[:limit]:
            last = row["seq"]
            try:
                engine.access.require_course_access(actor.user_id, row["course_id"])
            except DomainError as exc:
                if exc.status == 403:
                    continue
                raise
            items.append(json.loads(row["data"]))
        return dict(items=items, next_cursor=str(last), has_more=len(rows) > limit)
