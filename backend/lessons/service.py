import json
import re

from backend.assessment.questions import create_question
from backend.engine.db import now
from backend.engine.errors import DomainError, require
from backend.exams.generator import generate


def source_for_display(engine, connection, user, course, ref):
    """Expand a clipped ASCII word using adjacent source offsets, never invented text."""
    material = engine.db.get(connection, user, course, "material", ref["material_id"])
    page = material["pages"][ref["page"] - 1]["text"]
    start, end = ref["start"], ref["end"]

    def letter(char):
        return char.isascii() and char.isalpha()

    while start > 0 and start < len(page) and letter(page[start - 1]) and letter(page[start]):
        start -= 1
    while end < len(page) and end > 0 and letter(page[end - 1]) and letter(page[end]):
        end += 1
    if (start, end) == (ref["start"], ref["end"]):
        return ref["quote"], [ref]
    refs = []
    for chunk in material["chunks"]:
        if chunk["page"] != ref["page"]:
            continue
        first, last = max(start, chunk["start"]), min(end, chunk["end"])
        if first < last:
            refs.append(
                dict(
                    material_id=material["id"],
                    chunk_id=chunk["chunk_id"],
                    page=ref["page"],
                    quote=page[first:last],
                    start=first,
                    end=last,
                )
            )
    require(
        "".join(r["quote"] for r in refs) == page[start:end], "INVALID_SOURCE", "无法定位完整原文字词", 422
    )
    return page[start:end], refs


def split_for_display(text, limit=100, max_lines=3):
    """Prefer original line and word boundaries, keeping the source reading order."""
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    pieces = []
    while text:
        boundary = min(limit, len(text))
        newlines = [match.start() for match in re.finditer("\n", text[: boundary + 1])]
        if len(newlines) >= max_lines:
            boundary = newlines[max_lines - 1]
        elif boundary < len(text):
            # Prefer a line boundary when available, otherwise a word boundary.
            if newlines:
                boundary = newlines[-1]
            else:
                whitespace = list(re.finditer(r"\s+", text[: boundary + 1]))
                if whitespace:
                    boundary = whitespace[-1].start()
                else:
                    # Chinese can wrap between characters. Keep a whole Latin word together.
                    while boundary > 0 and text[boundary - 1].isascii() and text[boundary - 1].isalnum():
                        boundary -= 1
                    if boundary == 0:
                        boundary = limit
                        while boundary < len(text) and text[boundary].isascii() and text[boundary].isalnum():
                            boundary += 1
        if boundary <= 0:
            boundary = min(limit, len(text))
        piece = text[:boundary].strip()
        if piece:
            pieces.append(piece)
        text = text[boundary:].lstrip()
    return pieces


def register(engine):
    def lesson_job(job, payload):
        db, user, course = engine.db, job["user_id"], job["course_id"]
        lid = "lesson_" + job["job_id"]
        with db.transaction() as c:
            concepts = [db.get(c, user, course, "concept", cid) for cid in payload["concept_ids"]]
            pages, outline, question_drafts, warnings = [], [], [], []
            for index, concept in enumerate(concepts):
                outline.append(dict(concept_id=concept["id"], title=concept["title"]))
                # Text and narration are segmented before PPT export; both use the same pages.
                refs = concept["source_refs"]
                pieces = []
                for ref in refs:
                    text, display_refs = source_for_display(engine, c, user, course, ref)
                    if re.fullmatch(r"#{1,6}\s*.+", text):
                        continue
                    pieces.extend((piece, display_refs) for piece in split_for_display(text))
                for group in range(0, len(pieces), 3):
                    page_id = f"{lid}_p{len(pages) + 1}"
                    elements, segments = [], []
                    for n, (text, display_refs) in enumerate(pieces[group : group + 3]):
                        eid = f"{page_id}_e{n + 1}"
                        elements.append(
                            dict(element_id=eid, type="text", text=text, source_refs=display_refs)
                        )
                        segments.append(
                            dict(segment_id=f"{page_id}_s{n + 1}", text=text, highlight_element_ids=[eid])
                        )
                    pages.append(
                        dict(
                            page_id=page_id,
                            title=concept["title"],
                            concept_ids=[concept["id"]],
                            elements=elements,
                            narration_segments=segments,
                        )
                    )
                # Every lesson's practice is a regular B7 question, never a separate score store.
                try:
                    question_data = generate(concept, "cloze", "easy", 321, index)
                except DomainError as exc:
                    if exc.code != "INSUFFICIENT_SOURCE":
                        raise
                    outline[-1]["question_ids"] = []
                    warnings.append(
                        dict(concept_id=concept["id"], code=exc.code, message="该知识点来源不足，未生成随堂练习；可补充资料。")
                    )
                else:
                    qid = f"{lid}_q{index}"
                    question_drafts.append((qid, question_data))
                    outline[-1]["question_ids"] = [qid]
            require(pages, "INSUFFICIENT_SOURCE", "课程缺少可讲解的来源内容", 422)
            lesson = dict(
                id=lid,
                lesson_id=lid,
                title=payload["title"],
                outline=outline,
                pages=pages,
                generation_method="source_structured",
                generation_warnings=warnings,
                created_at=now(),
                pptx_filename=lid + ".pptx",
            )
        # Export before publishing the lesson. If export fails, the job remains retryable.
        from .export import export_pptx

        export_pptx(lesson, engine.files / lesson["pptx_filename"])
        (engine.files / (lid + ".json")).write_text(
            json.dumps(lesson, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        with db.transaction() as c:
            for qid, data in question_drafts:
                create_question(engine, c, user, course, data, key=qid, origin="lesson")
            db.put(c, user, course, "lesson", lesson)
            db.bump(c, user, course)
        return {"type": "lesson", "id": lid}

    engine.queue.handlers["lesson_generate"] = lesson_job
