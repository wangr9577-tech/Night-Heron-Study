from fastapi import APIRouter, Depends

from backend.engine.context import course_context, get_engine
from contracts.models import Ask, Search

from .service import ask, search

router = APIRouter(prefix="/api/v1/courses/{course_id}/tutoring", tags=["B3 教材检索与教学问答"])


@router.post("/search")
def retrieve(body: Search, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return {"items": search(engine, c, *ctx, body.query, body.limit), "method": "bm25"}


@router.post("/ask")
def answer(body: Ask, ctx=Depends(course_context), engine=Depends(get_engine)):
    return ask(engine, *ctx, body)
