import hashlib
import re
from pathlib import Path

from backend.engine.db import dumps, now
from backend.engine.errors import require
from backend.engine.jobs import public_job

from .parser import parse_file, structure

EXTENSIONS = {
    ".pdf",
    ".ppt",
    ".pptx",
    ".png",
    ".jpg",
    ".jpeg",
    ".webp",
    ".tif",
    ".tiff",
    ".bmp",
    ".txt",
    ".md",
}


def display_text(text):
    """Unwrap visual PDF line breaks for display; immutable source refs retain original offsets."""
    text = re.sub(r"(?<=[\u4e00-\u9fff])\n(?=[\u4e00-\u9fff])", "", text)
    return re.sub(r"\s*\n\s*", " ", text).strip()


def register(engine):
    def parse_job(job, payload):
        mid = payload["material_id"]
        with engine.db.connect() as c:
            material = engine.db.get(c, job["user_id"], job["course_id"], "material", mid)
        # Old duplicate jobs and recovered leases must never rewrite published source text.
        if material["status"] == "ready":
            return {"type": "material", "id": mid}
        pages = parse_file(engine.files / material["storage_name"], engine.settings.max_pages)
        chunks, chapters = structure(mid, pages)
        material.update(
            pages=pages, chunks=chunks, chapters=chapters, status="ready", parsed_at=now(), revision=1
        )
        with engine.db.transaction() as c:
            current = engine.db.get(c, job["user_id"], job["course_id"], "material", mid)
            if current["status"] == "ready":
                return {"type": "material", "id": mid}
            engine.db.put(c, job["user_id"], job["course_id"], "material", material)
            engine.db.bump(c, job["user_id"], job["course_id"])
        return {"type": "material", "id": mid}

    engine.queue.handlers["material_parse"] = parse_job


def receive(engine, c, user, course, filename, content, key=None):
    ext = Path(filename or "").suffix.lower()
    require(ext in EXTENSIONS, "UNSUPPORTED_FILE", "支持 PDF/PPT/PPTX/图片/TXT/MD", 415)
    require(content, "EMPTY_FILE", "文件为空", 422)
    digest = hashlib.sha256(content).hexdigest()
    # Same bytes within a user's course are a single material, including concurrent retries.
    mid = "mat_" + hashlib.sha256(f"{user}:{course}:{digest}:{ext}".encode()).hexdigest()[:32]
    payload = {"material_id": mid}
    request_hash = hashlib.sha256(dumps(payload).encode()).hexdigest()
    require(key is None or 1 <= len(key) <= 200, "INVALID_IDEMPOTENCY_KEY", "幂等键长度应为 1–200")
    if key:
        alias = c.execute(
            """SELECT * FROM b_idempotency WHERE user_id=? AND course_id=?
            AND scope='material_upload' AND key=?""",
            (user, course, key),
        ).fetchone()
        if alias:
            require(
                alias["request_hash"] == request_hash, "IDEMPOTENCY_CONFLICT", "相同幂等键对应不同文件", 409
            )
            return {"material_id": mid, "job": engine.queue.get(c, user, course, alias["entity_id"])}
        # Also honor keys written before material-upload aliases were introduced.
        legacy = c.execute(
            "SELECT * FROM b_jobs WHERE user_id=? AND course_id=? AND kind='material_parse' AND idempotency_key=?",
            (user, course, key),
        ).fetchone()
        require(
            not legacy or legacy["request_hash"] == request_hash,
            "IDEMPOTENCY_CONFLICT",
            "相同幂等键对应不同文件",
            409,
        )
    canonical = c.execute(
        """SELECT * FROM b_jobs WHERE user_id=? AND course_id=? AND kind='material_parse'
        AND request_hash=? ORDER BY created_at,job_id LIMIT 1""",
        (user, course, request_hash),
    ).fetchone()
    job = (
        public_job(canonical)
        if canonical
        else engine.queue.enqueue(c, user, course, "material_parse", payload, key or mid)
    )
    if key:
        c.execute(
            "INSERT INTO b_idempotency VALUES(?,?,'material_upload',?,?,?)",
            (user, course, key, request_hash, job["job_id"]),
        )
    existing = [m for m in engine.db.list(c, user, course, "material") if m["id"] == mid]
    if not existing:
        storage = mid + ext
        (engine.files / storage).write_bytes(content)
        engine.db.put(
            c,
            user,
            course,
            "material",
            dict(
                id=mid,
                filename=Path(filename).name,
                sha256=digest,
                storage_name=storage,
                status="uploaded",
                pages=[],
                chunks=[],
                chapters=[],
                revision=0,
                created_at=now(),
            ),
        )
    return {"material_id": mid, "job": job}


def validate_refs(engine, c, user, course, refs):
    output = []
    for ref in refs:
        ref = ref.model_dump() if hasattr(ref, "model_dump") else ref
        material = engine.db.get(c, user, course, "material", ref["material_id"])
        chunk = next((x for x in material["chunks"] if x["chunk_id"] == ref["chunk_id"]), None)
        require(chunk and chunk["page"] == ref["page"], "INVALID_SOURCE", "引用块或页码不匹配", 422)
        text = material["pages"][ref["page"] - 1]["text"]
        require(
            chunk["start"] <= ref["start"] < ref["end"] <= chunk["end"]
            and text[ref["start"] : ref["end"]] == ref["quote"],
            "INVALID_SOURCE",
            "引用文字与原文不一致",
            422,
        )
        output.append(ref)
    return output


def source_ref(material, chunk, quote=None):
    quote = quote or chunk["text"]
    offset = chunk["text"].find(quote)
    require(offset >= 0 and quote, "INVALID_SOURCE", "引用必须来自资料原文", 422)
    return dict(
        material_id=material["id"],
        chunk_id=chunk["chunk_id"],
        page=chunk["page"],
        quote=quote,
        start=chunk["start"] + offset,
        end=chunk["start"] + offset + len(quote),
    )
