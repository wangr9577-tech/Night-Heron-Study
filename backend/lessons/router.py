from fastapi import APIRouter, Depends
from fastapi.responses import FileResponse

from backend.engine.context import course_context, get_engine, idempotency_key
from backend.engine.db import now
from backend.engine.errors import require
from contracts.models import Job, Lesson, LessonGenerate, Position

router = APIRouter(prefix="/api/v1/courses/{course_id}/lessons", tags=["B4 结构化教学课程与 PPT"])


@router.post("", response_model=Job, status_code=202)
def generate_lesson(
    body: LessonGenerate,
    ctx=Depends(course_context),
    engine=Depends(get_engine),
    key=Depends(idempotency_key),
):
    with engine.db.transaction() as c:
        for cid in body.concept_ids:
            engine.db.get(c, *ctx, "concept", cid)
        return engine.queue.enqueue(c, *ctx, "lesson_generate", body.model_dump(), key)


@router.get("")
def list_lessons(ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return {"items": engine.db.list(c, *ctx, "lesson")}


@router.get("/{lesson_id}", response_model=Lesson)
def get_lesson(lesson_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return engine.db.get(c, *ctx, "lesson", lesson_id)


@router.get("/{lesson_id}/pptx")
def get_pptx(lesson_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        lesson = engine.db.get(c, *ctx, "lesson", lesson_id)
    return FileResponse(
        engine.files / lesson["pptx_filename"],
        filename=lesson_id + ".pptx",
        media_type="application/vnd.openxmlformats-officedocument.presentationml.presentation",
    )


@router.put("/{lesson_id}/position")
def save_position(lesson_id: str, body: Position, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        lesson = engine.db.get(c, *ctx, "lesson", lesson_id)
        page = next((p for p in lesson["pages"] if p["page_id"] == body.page_id), None)
        require(
            page and body.segment_id in [s["segment_id"] for s in page["narration_segments"]],
            "INVALID_POSITION",
            "页面或讲解分段不存在",
            422,
        )
        return engine.db.put(
            c,
            *ctx,
            "position",
            dict(id="position_" + lesson_id, lesson_id=lesson_id, **body.model_dump(), updated_at=now()),
        )


@router.get("/{lesson_id}/position")
def get_position(lesson_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        engine.db.get(c, *ctx, "lesson", lesson_id)
        positions = engine.db.list(c, *ctx, "position")
        return next((p for p in positions if p["lesson_id"] == lesson_id), None)
