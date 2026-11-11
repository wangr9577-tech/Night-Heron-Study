from fastapi import APIRouter, Depends
from fastapi.responses import FileResponse

from backend.assessment.questions import create_question, public_question
from backend.assessment.support import record_answer_view
from backend.engine.context import author_context, course_context, get_engine, idempotency_key
from backend.engine.db import now
from backend.engine.errors import require
from backend.engine.review_access import review_queue, review_target
from contracts.models import (
    Job,
    MistakeCapture,
    MistakeConfirm,
    MistakeDiagnosis,
    MistakeTranscription,
    VariantGenerate,
)

from .service import capture

router = APIRouter(prefix="/api/v1/courses/{course_id}/mistakes", tags=["B6 错题、校对、变式与分步讲解"])


@router.get("")
def list_mistakes(
    concept_id: str | None = None,
    status: str | None = None,
    ctx=Depends(course_context),
    engine=Depends(get_engine),
):
    with engine.db.connect() as c:
        return {
            "items": [
                m
                for m in engine.db.list(c, *ctx, "mistake")
                if (not concept_id or concept_id in m["concept_ids"])
                and (not status or m["status"] == status)
            ]
        }


@router.post("/capture", status_code=201)
def capture_mistake(body: MistakeCapture, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        return capture(engine, c, *ctx, body)


@router.get("/review-queue")
def pending_captures(ctx=Depends(author_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        items = review_queue(engine, c, ctx[1], "mistake", "needs_confirmation", reviewer=ctx[0])
        for item in items:
            item["available_concepts"] = engine.db.list(c, item["user_id"], ctx[1], "concept")
        return {"items": items}


@router.patch("/{mistake_id}/transcription")
def transcribe(
    mistake_id: str, body: MistakeTranscription, ctx=Depends(course_context), engine=Depends(get_engine)
):
    with engine.db.transaction() as c:
        m = engine.db.get(c, *ctx, "mistake", mistake_id)
        require(m["status"] == "needs_confirmation", "ALREADY_CONFIRMED", "已审核错题不能覆盖原题", 409)
        m.update(corrected_question=body.text, transcription_updated_at=now())
        return engine.db.put(c, *ctx, "mistake", m)


@router.get("/{mistake_id}")
def detail(mistake_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        m = engine.db.get(c, *ctx, "mistake", mistake_id)
        attempts = [
            a
            for a in engine.db.list(c, *ctx, "attempt")
            if a["question_id"] == m["question_id"] or a["question_id"] in m["variant_ids"]
        ]
        for a in attempts:
            if a["status"] == "graded":
                record_answer_view(engine, c, *ctx, a["question_id"], "feedback_view")
        return dict(
            m,
            attempts=attempts,
            variants=[public_question(engine.db.get(c, *ctx, "question", qid)) for qid in m["variant_ids"]],
        )


@router.post("/{mistake_id}/confirm")
def confirm(mistake_id: str, body: MistakeConfirm, ctx=Depends(author_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        owner_ctx, m = review_target(engine, c, ctx[1], "mistake", mistake_id, reviewer=ctx[0])
        require(
            m["status"] == "needs_confirmation",
            "ALREADY_CONFIRMED",
            "此错题已校对，原题与作答历史保持不变",
            409,
        )
        q = create_question(
            engine, c, *owner_ctx, body.question, key="captured_" + mistake_id, origin="confirmed_capture"
        )
        m.update(
            question_id=q["id"],
            concept_ids=q["concept_ids"],
            corrected_question=q["prompt"],
            error_cause=body.error_cause,
            status="confirmed",
            confirmed_at=now(),
            confirmed_by=ctx[0],
        )
        return engine.db.put(c, *owner_ctx, "mistake", m)


@router.get("/{mistake_id}/review-original")
def review_original(mistake_id: str, ctx=Depends(author_context), engine=Depends(get_engine)):
    """An authorized independent reviewer may inspect the student's captured original."""
    with engine.db.connect() as c:
        owner_ctx, m = review_target(engine, c, ctx[1], "mistake", mistake_id, reviewer=ctx[0])
        require(m.get("material_id"), "NOT_FOUND", "此错题没有上传的原件", 404)
        material = engine.db.get(c, *owner_ctx, "material", m["material_id"])
        path = engine.files / material["storage_name"]
        require(path.is_file(), "NOT_FOUND", "原件文件不存在", 404)
        return FileResponse(path, filename=material["filename"])


@router.patch("/{mistake_id}/diagnosis")
def diagnose(
    mistake_id: str, body: MistakeDiagnosis, ctx=Depends(course_context), engine=Depends(get_engine)
):
    with engine.db.transaction() as c:
        m = engine.db.get(c, *ctx, "mistake", mistake_id)
        m["error_cause"] = body.error_cause
        return engine.db.put(c, *ctx, "mistake", m)


@router.post("/{mistake_id}/variants", response_model=Job, status_code=202)
def variants(
    mistake_id: str,
    body: VariantGenerate,
    ctx=Depends(course_context),
    engine=Depends(get_engine),
    key=Depends(idempotency_key),
):
    with engine.db.transaction() as c:
        m = engine.db.get(c, *ctx, "mistake", mistake_id)
        require(m["status"] == "confirmed", "MISTAKE_NOT_CONFIRMED", "请先校对错题", 409)
        return engine.queue.enqueue(
            c, *ctx, "variant_generate", dict(body.model_dump(), mistake_id=mistake_id), key
        )


@router.get("/{mistake_id}/explanation")
def explanation(mistake_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        m = engine.db.get(c, *ctx, "mistake", mistake_id)
        require(m["question_id"], "MISTAKE_NOT_CONFIRMED", "请先校对错题", 409)
        q = engine.db.get(c, *ctx, "question", m["question_id"])
        record_answer_view(engine, c, *ctx, q["id"], "mistake_explanation")
        steps = q.get("steps", [q["explanation"]])
        return dict(
            question_id=q["id"],
            steps=[
                dict(
                    step_id=f"{q['id']}_step{index + 1}",
                    text=text,
                    elements=[dict(element_id=f"{q['id']}_e{index + 1}", type="text", text=text)],
                    highlight_element_ids=[f"{q['id']}_e{index + 1}"],
                )
                for index, text in enumerate(steps)
            ],
            source_refs=q["source_refs"],
            audio_provider="A7",
        )
