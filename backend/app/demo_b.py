"""Explicitly labeled, isolated B-side sample data, without real learning events."""

import json

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .core import current_user, db, new_id, now, require_course

router = APIRouter(prefix="/api/v1")
NOTICE = "演示样例，不代表真实课程内容或学习成果"


def init_demo_b():
    with db() as c:
        c.execute(
            "CREATE TABLE IF NOT EXISTS demo_attempts (attempt_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,course_id TEXT NOT NULL,data TEXT NOT NULL)"
        )


def allowed(uid, course_id):
    with db() as c:
        require_course(c, uid, course_id)


def resource_course(value, prefix, uid):
    if not value.startswith(prefix) or not value[len(prefix) :].startswith("crs_"):
        raise HTTPException(404, "演示资源不存在")
    cid = value[len(prefix) :]
    allowed(uid, cid)
    return cid


def material(cid):
    return {
        "material_id": "mat_demo_" + cid,
        "course_id": cid,
        "title": "演示资料：函数基础",
        "file_type": "pdf",
        "page_count": 1,
        "status": "ready",
        "import_job_id": None,
        "is_demo": True,
    }


def node(cid):
    return {
        "node_id": "nod_demo_" + cid,
        "concept_id": "con_demo_" + cid,
        "name": "一次函数",
        "description": "演示知识点：形如 y = kx + b 的函数。",
        "mastery": None,
        "source_refs": [
            {
                "material_id": "mat_demo_" + cid,
                "page": 1,
                "block_id": "blk_demo",
                "snippet": "一次函数可写作 y = kx + b。",
            }
        ],
        "is_demo": True,
    }


def lesson(cid):
    return {
        "lesson_id": "les_demo_" + cid,
        "course_id": cid,
        "title": "演示课程：一次函数",
        "page_count": 1,
        "is_demo": True,
        "pages": [
            {
                "page_id": "pg_demo_" + cid,
                "order": 1,
                "elements": [{"element_id": "el_demo", "type": "formula", "content": "y = kx + b"}],
                "explanation_segments": [
                    {
                        "segment_id": "seg_demo_" + cid,
                        "order": 1,
                        "text": "k 表示斜率，b 表示纵截距。",
                        "highlight_element_ids": ["el_demo"],
                    }
                ],
            }
        ],
    }


def question(cid):
    return {
        "question_id": "qst_demo_" + cid,
        "concept_ids": ["con_demo_" + cid],
        "type": "blank",
        "stem": "若 y = 2x + 1，当 x = 1 时 y 等于多少？",
        "answer_hint_available": True,
        "is_demo": True,
    }


@router.get("/materials")
def materials(course_id: str, uid: str = Depends(current_user)):
    allowed(uid, course_id)
    return {"items": [material(course_id)], "is_demo": True, "notice": NOTICE}


@router.get("/materials/{material_id}")
def material_detail(material_id: str, uid: str = Depends(current_user)):
    cid = resource_course(material_id, "mat_demo_", uid)
    return {
        **material(cid),
        "chapters": [{"chapter_id": "ch_demo", "title": "一次函数", "page_start": 1}],
        "pages": [
            {
                "page_no": 1,
                "blocks": [{"block_id": "blk_demo", "type": "text", "text": "一次函数可写作 y = kx + b。"}],
            }
        ],
        "notice": NOTICE,
    }


@router.get("/courses/{course_id}/graph")
def graph(course_id: str, uid: str = Depends(current_user)):
    allowed(uid, course_id)
    return {"nodes": [node(course_id)], "edges": [], "is_demo": True, "notice": NOTICE}


@router.get("/graph/nodes/{node_id}")
def graph_node(node_id: str, uid: str = Depends(current_user)):
    cid = resource_course(node_id, "nod_demo_", uid)
    return {**node(cid), "notice": NOTICE}


@router.get("/graph/nodes/{node_id}/sources")
def graph_sources(node_id: str, uid: str = Depends(current_user)):
    cid = resource_course(node_id, "nod_demo_", uid)
    return {"items": node(cid)["source_refs"], "is_demo": True, "notice": NOTICE}


@router.get("/lessons")
def lessons(course_id: str, uid: str = Depends(current_user)):
    allowed(uid, course_id)
    return {
        "items": [
            {
                "lesson_id": "les_demo_" + course_id,
                "course_id": course_id,
                "title": "演示课程：一次函数",
                "page_count": 1,
                "published_at": None,
                "is_demo": True,
            }
        ],
        "is_demo": True,
        "notice": NOTICE,
    }


@router.get("/lessons/{lesson_id}")
def lesson_detail(lesson_id: str, uid: str = Depends(current_user)):
    cid = resource_course(lesson_id, "les_demo_", uid)
    return {**lesson(cid), "notice": NOTICE}


@router.get("/lessons/{lesson_id}/quiz")
def quiz(lesson_id: str, uid: str = Depends(current_user)):
    cid = resource_course(lesson_id, "les_demo_", uid)
    return {"items": [question(cid)], "is_demo": True, "notice": NOTICE}


class Ask(BaseModel):
    course_id: str
    question: str = Field(min_length=1, max_length=3000)
    mode: str = "explain"
    concept_id: str | None = None
    hint_level: int | None = None


@router.post("/tutoring/ask")
def ask(body: Ask, uid: str = Depends(current_user)):
    allowed(uid, body.course_id)
    if body.mode not in ("explain", "socratic", "hint"):
        raise HTTPException(400, "未知问答模式")
    # Do not pretend the fixed text answers an arbitrary question.
    return {
        "answer_id": new_id("ans"),
        "text": "演示问答尚未接入教学引擎，无法回答这个问题。样例提示：一次函数 y = kx + b 中，k 是斜率。",
        "mode": body.mode,
        "hint_level": body.hint_level,
        "source_refs": node(body.course_id)["source_refs"],
        "next_hint_available": False,
        "is_demo": True,
        "notice": NOTICE,
    }


class AttemptInput(BaseModel):
    question_id: str
    course_id: str
    answer: str = Field(max_length=2000)
    hints_used: list[str] = Field(default_factory=list)
    source_task_id: str | None = None


@router.post("/attempts")
def attempt(body: AttemptInput, uid: str = Depends(current_user)):
    allowed(uid, body.course_id)
    if body.question_id != "qst_demo_" + body.course_id:
        raise HTTPException(404, "演示题目不存在")
    correct = body.answer.strip() == "3"
    stamp = now()
    result = {
        "attempt_id": new_id("att"),
        "question_id": body.question_id,
        "course_id": body.course_id,
        "concept_ids": ["con_demo_" + body.course_id],
        "answer": body.answer,
        "score": 10 if correct else 0,
        "max_score": 10,
        "is_correct": correct,
        "hints_used": body.hints_used,
        "grading_basis": "演示题答案为 3。",
        "source_task_id": body.source_task_id,
        "status": "graded",
        "submitted_at": stamp,
        "graded_at": stamp,
        "is_demo": True,
        "notice": "演示判分，不更新掌握状态、不完成任务、不产生奖励",
    }
    with db() as c:
        c.execute(
            "INSERT INTO demo_attempts VALUES (?,?,?,?)",
            (result["attempt_id"], uid, body.course_id, json.dumps(result, ensure_ascii=False)),
        )
    return result


@router.get("/attempts/{attempt_id}")
def attempt_detail(attempt_id: str, uid: str = Depends(current_user)):
    with db() as c:
        row = c.execute(
            "SELECT course_id,data FROM demo_attempts WHERE attempt_id=? AND user_id=?", (attempt_id, uid)
        ).fetchone()
        if not row:
            raise HTTPException(404, "演示作答不存在")
        require_course(c, uid, row["course_id"])
        return json.loads(row["data"])


@router.get("/mistakes")
def mistakes(course_id: str, uid: str = Depends(current_user)):
    allowed(uid, course_id)
    return {"items": [], "is_demo": True, "notice": "演示模式：暂无错题，真实错题服务未接入"}


@router.get("/reviews/due")
def reviews(course_id: str, date: str | None = None, uid: str = Depends(current_user)):
    allowed(uid, course_id)
    return {"items": [], "is_demo": True, "notice": "演示模式：真实复习服务未接入"}
