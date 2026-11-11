"""Small compatibility facade for the uploaded Flutter client's A-side paths.

B's course-scoped API and data contracts remain unchanged. No facade fabricates
learning content, grades, mastery, or completion events.
"""

from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, UploadFile
from pydantic import BaseModel, Field

from backend.assessment.questions import public_question
from backend.assessment.router import attempt as b_attempt
from backend.engine.errors import require
from backend.knowledge.router import graph as b_graph
from backend.lessons.router import get_lesson
from backend.materials.router import material as b_material
from backend.materials.router import materials as b_materials
from backend.materials.router import upload as b_upload
from backend.mistakes.router import detail as b_mistake
from backend.review.router import reviews as b_reviews
from backend.tutoring.service import ask
from contracts.models import Ask, AttemptSubmit

from .core import current_user
from .integration import engine, locate, snapshot

router = APIRouter(prefix="/api/v1", tags=["Flutter 路径适配"])


def material_out(value):
    return dict(
        value,
        material_id=value["id"],
        title=value["filename"],
        pages=[
            dict(page_no=p["page"], blocks=[dict(type="text", text=p["text"])])
            for p in value.get("pages", [])
        ],
    )


@router.get("/materials")
def materials(course_id: str, user=Depends(current_user)):
    service = engine()
    service.access.require_course_access(user, course_id)
    return dict(items=[material_out(m) for m in b_materials(ctx=(user, course_id), engine=service)["items"]])


@router.post("/materials", status_code=202)
def upload(
    course_id: str = Form(...),
    file: UploadFile = File(...),
    user=Depends(current_user),
    key: str | None = Header(None, alias="Idempotency-Key"),
):
    service = engine()
    service.access.require_course_access(user, course_id)
    value = b_upload(file=file, ctx=(user, course_id), engine=service, key=key)
    return dict(value, job_id=value["job"]["job_id"], course_id=course_id)


@router.get("/materials/{material_id}")
def material(material_id: str, user=Depends(current_user)):
    course, _ = locate(user, "material", material_id)
    return material_out(b_material(material_id, ctx=(user, course), engine=engine()))


@router.get("/jobs/{job_id}")
def job(job_id: str, user=Depends(current_user)):
    service = engine()
    with service.db.connect() as c:
        row = c.execute(
            "SELECT course_id FROM b_jobs WHERE job_id=? AND user_id=?", (job_id, user)
        ).fetchone()
        if not row:
            raise HTTPException(404, "后台任务不存在或无访问权限")
        service.access.require_course_access(user, row["course_id"])
        return dict(service.queue.get(c, user, row["course_id"], job_id), course_id=row["course_id"])


@router.get("/courses/{course_id}/graph")
def graph(course_id: str, user=Depends(current_user)):
    service = engine()
    state = snapshot(user, course_id)
    mastery = {s["concept_id"]: s.get("mastery") for s in state["concept_states"]}
    data = b_graph(ctx=(user, course_id), engine=service)
    return dict(
        nodes=[
            dict(n, node_id=n["id"], concept_id=n["id"], name=n["title"], mastery=mastery.get(n["id"]))
            for n in data["nodes"]
        ],
        edges=data["edges"],
    )


@router.get("/graph/nodes/{node_id}")
def graph_node(node_id: str, user=Depends(current_user)):
    course, value = locate(user, "concept", node_id)
    return dict(value, node_id=node_id, concept_id=node_id, name=value["title"], course_id=course)


def lesson_out(value, course):
    return dict(
        value,
        lesson_id=value["id"],
        course_id=course,
        page_count=len(value["pages"]),
        pages=[
            dict(p, order=i + 1, explanation_segments=p["narration_segments"])
            for i, p in enumerate(value["pages"])
        ],
    )


@router.get("/lessons")
def lessons(course_id: str, user=Depends(current_user)):
    service = engine()
    service.access.require_course_access(user, course_id)
    with service.db.connect() as c:
        return dict(items=[lesson_out(v, course_id) for v in service.db.list(c, user, course_id, "lesson")])


@router.get("/lessons/{lesson_id}")
def lesson(lesson_id: str, user=Depends(current_user)):
    course, _ = locate(user, "lesson", lesson_id)
    return lesson_out(get_lesson(lesson_id, ctx=(user, course), engine=engine()), course)


def question_out(q):
    return dict(public_question(q), question_id=q["id"], stem=q["prompt"], type=q["kind"])


@router.get("/lessons/{lesson_id}/quiz")
def quiz(lesson_id: str, user=Depends(current_user)):
    course, lesson_value = locate(user, "lesson", lesson_id)
    concept_ids = {cid for p in lesson_value["pages"] for cid in p["concept_ids"]}
    service = engine()
    with service.db.connect() as c:
        return dict(
            items=[
                question_out(q)
                for q in service.db.list(c, user, course, "question")
                if concept_ids.intersection(q["concept_ids"])
            ]
        )


class LegacyAttempt(BaseModel):
    course_id: str
    question_id: str
    answer: str = Field(max_length=6000)
    practice_session_id: str
    source_task_id: str | None = None
    exam_id: str | None = None
    review_id: str | None = None


@router.post("/attempts", status_code=201)
def attempt(
    body: LegacyAttempt, user=Depends(current_user), key: str | None = Header(None, alias="Idempotency-Key")
):
    service = engine()
    service.access.require_course_access(user, body.course_id)
    result = b_attempt(
        AttemptSubmit(**body.model_dump(exclude={"course_id"})),
        ctx=(user, body.course_id),
        engine=service,
        key=key,
    )
    return dict(
        result,
        max_score=1,
        is_correct=result.get("score") == 1,
        grading_basis=result.get("grading_rationale"),
    )


class LegacyAsk(BaseModel):
    course_id: str
    question: str = Field(min_length=1, max_length=3000)
    mode: str = "explain"
    concept_id: str | None = None
    hint_level: int | None = None


@router.post("/tutoring/ask")
def tutoring(body: LegacyAsk, user=Depends(current_user)):
    service = engine()
    service.access.require_course_access(user, body.course_id)
    require(body.mode != "hint", "PRACTICE_SESSION_REQUIRED", "请从练习页申请提示，以便记录辅助程度", 422)
    value = ask(service, user, body.course_id, Ask(question=body.question, mode=body.mode))
    return dict(value, text=value["answer"], source_refs=value.get("sources", []))


@router.get("/mistakes")
def mistakes(course_id: str, user=Depends(current_user)):
    service = engine()
    service.access.require_course_access(user, course_id)
    with service.db.connect() as c:
        return dict(
            items=[
                dict(
                    m,
                    mistake_id=m["id"],
                    title=m.get("corrected_question") or m.get("recognized_question") or "错题",
                )
                for m in service.db.list(c, user, course_id, "mistake")
            ]
        )


@router.get("/mistakes/{mistake_id}")
def mistake(mistake_id: str, user=Depends(current_user)):
    course, _ = locate(user, "mistake", mistake_id)
    return dict(b_mistake(mistake_id, ctx=(user, course), engine=engine()), course_id=course)


@router.get("/reviews/due")
def reviews(course_id: str, date: str | None = None, user=Depends(current_user)):
    service = engine()
    service.access.require_course_access(user, course_id)
    result = b_reviews(due_only=True, ctx=(user, course_id), engine=service)
    with service.db.connect() as c:
        return dict(
            items=[
                dict(
                    v,
                    review_id=v["id"],
                    target_id=v["id"],
                    title=service.db.get(c, user, course_id, "question", v["question_id"])["prompt"],
                )
                for v in result["items"]
            ]
        )
