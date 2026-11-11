from fastapi import APIRouter, Depends

from backend.engine.context import (
    author_context,
    course_context,
    get_engine,
    idempotency_key,
    reviewer_context,
)
from backend.engine.errors import require
from backend.engine.review_access import review_queue, review_target
from contracts.models import AttemptResult, AttemptSubmit, ManualGrade, QuestionCreate, QuestionSourceView

from .questions import create_question, public_question
from .service import new_session, settle, submit
from .support import record_answer_view

router = APIRouter(prefix="/api/v1/courses/{course_id}", tags=["B7 题库、统一作答与掌握证据"])


@router.post("/questions", status_code=201)
def question_create(body: QuestionCreate, ctx=Depends(author_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        return create_question(engine, c, *ctx, body)


@router.get("/questions")
def questions(ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return {"items": [public_question(q) for q in engine.db.list(c, *ctx, "question")]}


@router.get("/questions/{question_id}")
def question(question_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return public_question(engine.db.get(c, *ctx, "question", question_id))


@router.get("/questions/{question_id}/answer-key")
def answer_key(question_id: str, ctx=Depends(author_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        question = engine.db.get(c, *ctx, "question", question_id)
        record_answer_view(engine, c, *ctx, question_id, "answer_key")
        return question


@router.post("/questions/{question_id}/sessions", status_code=201)
def session(question_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        return new_session(engine, c, *ctx, question_id)


@router.post("/questions/{question_id}/sources")
def question_sources(
    question_id: str, body: QuestionSourceView, ctx=Depends(course_context), engine=Depends(get_engine)
):
    from backend.engine.db import now

    with engine.db.transaction() as c:
        q = engine.db.get(c, *ctx, "question", question_id)
        s = engine.db.get(c, *ctx, "practice_session", body.practice_session_id)
        require(
            s["question_id"] == question_id and not s["submitted"],
            "INVALID_SESSION",
            "会话不匹配或已提交",
            409,
        )
        s["hint_records"].append(dict(mode="source_view", level=None, occurred_at=now()))
        s["solution_viewed"] = True
        engine.db.put(c, *ctx, "practice_session", s)
        return {"sources": q["source_refs"], "answer_exposed": True}


@router.get("/assessment/review-queue")
def pending_reviews(ctx=Depends(reviewer_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        items = review_queue(engine, c, ctx[1], "attempt", "pending_review", reviewer=ctx[0])
        for item in items:
            item["question"] = engine.db.get(c, item["user_id"], ctx[1], "question", item["question_id"])
        return {"items": items}


@router.post("/attempts", status_code=201, response_model=AttemptResult)
def attempt(
    body: AttemptSubmit, ctx=Depends(course_context), engine=Depends(get_engine), key=Depends(idempotency_key)
):
    with engine.db.transaction() as c:
        return submit(engine, c, *ctx, body, key)


@router.get("/attempts/{attempt_id}", response_model=AttemptResult)
def attempt_get(attempt_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        result = engine.db.get(c, *ctx, "attempt", attempt_id)
        if result["status"] == "graded":
            record_answer_view(engine, c, *ctx, result["question_id"], "feedback_view")
        return result


@router.post("/attempts/{attempt_id}/grade", response_model=AttemptResult)
def manual_grade(
    attempt_id: str, body: ManualGrade, ctx=Depends(reviewer_context), engine=Depends(get_engine)
):
    with engine.db.transaction() as c:
        owner_ctx, a = review_target(engine, c, ctx[1], "attempt", attempt_id, reviewer=ctx[0])
        require(a["status"] == "pending_review", "ALREADY_GRADED", "作答不在待审核状态", 409)
        q = engine.db.get(c, *owner_ctx, "question", a["question_id"])
        a["reviewed_by"] = ctx[0]
        return settle(engine, c, *owner_ctx, a, q, body.score, body.rationale, "human_rubric")


@router.get("/mastery")
def mastery(ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return {
            "items": engine.db.list(c, *ctx, "mastery"),
            "model": "weighted_beta_evidence_v1",
            "irt_calibrated": False,
        }
