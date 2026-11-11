import json
import re

from fastapi import APIRouter, Depends
from fastapi.responses import FileResponse

from backend.assessment.questions import public_question
from backend.assessment.support import record_answer_view
from backend.engine.context import author_context, course_context, get_engine, idempotency_key
from backend.engine.db import now, uid
from backend.engine.errors import require
from backend.engine.jobs import public_job
from contracts.models import BlueprintCreate, ExamAnalyze, ExamGenerate, Job

from .service import analyze, validate_blueprint

router = APIRouter(prefix="/api/v1/courses/{course_id}", tags=["B5 仿真试卷"])


@router.post("/exams/analyze")
def analyze_original(body: ExamAnalyze, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        return analyze(engine, c, *ctx, body.material_id)


@router.post("/exam-blueprints", status_code=201)
def create_blueprint(body: BlueprintCreate, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        data = validate_blueprint(engine, c, *ctx, body.model_dump())
        return engine.db.put(
            c, *ctx, "blueprint", dict(data, id=uid("blueprint"), revision=1, created_at=now())
        )


@router.get("/exam-blueprints/{blueprint_id}")
def get_blueprint(blueprint_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return engine.db.get(c, *ctx, "blueprint", blueprint_id)


@router.put("/exam-blueprints/{blueprint_id}")
def update_blueprint(
    blueprint_id: str, body: BlueprintCreate, ctx=Depends(course_context), engine=Depends(get_engine)
):
    with engine.db.transaction() as c:
        bp = engine.db.get(c, *ctx, "blueprint", blueprint_id)
        data = validate_blueprint(engine, c, *ctx, body.model_dump())
        bp.update(data, revision=bp["revision"] + 1)
        return engine.db.put(c, *ctx, "blueprint", bp)


@router.post("/exams", response_model=Job, status_code=202)
def generate_exam(
    body: ExamGenerate, ctx=Depends(course_context), engine=Depends(get_engine), key=Depends(idempotency_key)
):
    with engine.db.transaction() as c:
        if key:
            previous = c.execute(
                """SELECT * FROM b_jobs WHERE user_id=? AND course_id=?
                AND kind='exam_generate' AND idempotency_key=?""",
                (*ctx, key),
            ).fetchone()
            if previous:
                saved = json.loads(previous["payload"])
                # Legacy jobs stored only the frozen blueprint ID; recover their original request.
                original = saved.get("request") or dict(
                    saved, blueprint_id=re.sub(r"_r\d+$", "", saved["blueprint_id"])
                )
                require(original == body.model_dump(), "IDEMPOTENCY_CONFLICT", "相同幂等键对应不同请求", 409)
                return public_job(previous)
        bp = engine.db.get(c, *ctx, "blueprint", body.blueprint_id)
        # Freeze the requested revision: later UI changes must not change a queued job's exam.
        snapshot_key = bp["id"] + "_r" + str(bp["revision"])
        engine.db.put(c, *ctx, "blueprint", dict(bp, id=snapshot_key))
        payload = dict(body.model_dump(), blueprint_id=snapshot_key, request=body.model_dump())
        return engine.queue.enqueue(c, *ctx, "exam_generate", payload, key)


@router.get("/exams")
def list_exams(ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return {"items": engine.db.list(c, *ctx, "exam")}


@router.get("/exams/{exam_id}")
def get_exam(exam_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        exam = engine.db.get(c, *ctx, "exam", exam_id)
        return dict(
            exam,
            questions=[
                public_question(engine.db.get(c, *ctx, "question", i["question_id"])) for i in exam["items"]
            ],
        )


@router.get("/exams/{exam_id}/results")
def exam_results(exam_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        exam = engine.db.get(c, *ctx, "exam", exam_id)
        attempts = [a for a in engine.db.list(c, *ctx, "attempt") if a.get("exam_id") == exam_id]
        for a in attempts:
            if a["status"] == "graded":
                record_answer_view(engine, c, *ctx, a["question_id"], "feedback_view")
        latest = {a["question_id"]: a for a in attempts}
        return dict(
            exam_id=exam_id,
            attempts=attempts,
            score=sum(
                (latest[i["question_id"]]["score"] or 0) * i["points"]
                for i in exam["items"]
                if i["question_id"] in latest
            ),
            total_points=exam["total_points"],
            graded_count=sum(a["status"] == "graded" for a in latest.values()),
            question_count=len(exam["items"]),
        )


@router.get("/exams/{exam_id}/paper")
def paper(exam_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        exam = engine.db.get(c, *ctx, "exam", exam_id)
    return FileResponse(
        engine.files / exam["paper_filename"], media_type="application/pdf", filename=exam_id + "-paper.pdf"
    )


@router.get("/exams/{exam_id}/answers")
def answers(exam_id: str, ctx=Depends(author_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        exam = engine.db.get(c, *ctx, "exam", exam_id)
    return FileResponse(
        engine.files / exam["answers_filename"],
        media_type="application/pdf",
        filename=exam_id + "-answers.pdf",
    )
