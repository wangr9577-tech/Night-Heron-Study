from fastapi import APIRouter, Depends, File, UploadFile
from fastapi.responses import FileResponse

from backend.engine.context import course_context, get_engine, idempotency_key
from backend.engine.db import now
from backend.engine.errors import require
from contracts.models import Job, MaterialCorrection

from .service import receive

router = APIRouter(prefix="/api/v1/courses/{course_id}", tags=["B1 资料与后台任务"])


@router.post("/materials", status_code=202)
def upload(
    file: UploadFile = File(...),
    ctx=Depends(course_context),
    engine=Depends(get_engine),
    key=Depends(idempotency_key),
):
    content = file.file.read(engine.settings.max_upload_mb * 1024 * 1024 + 1)
    require(
        len(content) <= engine.settings.max_upload_mb * 1024 * 1024,
        "UPLOAD_TOO_LARGE",
        "文件超过上传限制",
        413,
    )
    with engine.db.transaction() as c:
        return receive(engine, c, *ctx, file.filename, content, key)


@router.get("/materials")
def materials(ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return {
            "items": [
                {k: v for k, v in m.items() if k not in {"storage_name", "pages", "chunks"}}
                for m in engine.db.list(c, *ctx, "material")
            ]
        }


@router.get("/materials/{material_id}")
def material(material_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        data = engine.db.get(c, *ctx, "material", material_id)
        return {k: v for k, v in data.items() if k != "storage_name"}


@router.get("/materials/{material_id}/original")
def original(material_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        m = engine.db.get(c, *ctx, "material", material_id)
    return FileResponse(engine.files / m["storage_name"], filename=m["filename"])


@router.patch("/materials/{material_id}/chunks")
def correct(
    material_id: str, body: MaterialCorrection, ctx=Depends(course_context), engine=Depends(get_engine)
):
    with engine.db.transaction() as c:
        m = engine.db.get(c, *ctx, "material", material_id)
        # Once cited, modifying source text would silently invalidate grading/lesson evidence.
        dependent = [
            entity
            for kind in ["concept", "question", "lesson", "mistake", "tutoring_reply"]
            for entity in engine.db.list(c, *ctx, kind)
            if material_id in str(entity)
        ]
        require(not dependent, "SOURCE_IN_USE", "资料已被引用，请上传修订版本以保留历史来源", 409)
        chunk = next((ch for ch in m["chunks"] if ch["chunk_id"] == body.chunk_id), None)
        require(chunk is not None, "NOT_FOUND", "资料块不存在", 404)
        page = m["pages"][chunk["page"] - 1]
        page["text"] = page["text"][: chunk["start"]] + body.text + page["text"][chunk["end"] :]
        page["method"] = "human_corrected"
        from .parser import structure

        m["chunks"], m["chapters"] = structure(material_id, m["pages"])
        m["revision"] += 1
        m["corrected_at"] = now()
        engine.db.put(c, *ctx, "material", m)
        return {k: v for k, v in m.items() if k != "storage_name"}


@router.get("/jobs/{job_id}", response_model=Job)
def job(job_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return engine.queue.get(c, *ctx, job_id)


@router.get("/jobs", response_model=list[Job])
def jobs(ctx=Depends(course_context), engine=Depends(get_engine)):
    from backend.engine.jobs import public_job

    from . import service  # noqa: F401

    with engine.db.connect() as c:
        return [
            public_job(r)
            for r in c.execute(
                "SELECT * FROM b_jobs WHERE user_id=? AND course_id=? ORDER BY created_at DESC LIMIT 100", ctx
            )
        ]


@router.post("/jobs/{job_id}/retry", response_model=Job, status_code=202)
def retry(job_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        return engine.queue.retry(c, *ctx, job_id)
