from backend.assessment.questions import create_question
from backend.engine.db import now, uid
from backend.engine.errors import require
from backend.exams.generator import generate


def capture(engine, c, user, course, body):
    material = engine.db.get(c, user, course, "material", body.material_id)
    require(material["status"] == "ready", "MATERIAL_NOT_READY", "请等待图片/试卷解析完成", 409)
    require(body.page <= len(material["pages"]), "INVALID_PAGE", "原资料中无此页", 422)
    for cid in body.concept_ids:
        engine.db.get(c, user, course, "concept", cid)
    page = material["pages"][body.page - 1]
    from backend.materials.service import source_ref

    refs = [source_ref(material, ch) for ch in material["chunks"] if ch["page"] == body.page]
    return engine.db.put(
        c,
        user,
        course,
        "mistake",
        dict(
            id=uid("mistake"),
            material_id=body.material_id,
            original_question=page["text"],
            original_answer=body.original_answer,
            recognized_text=page["text"],
            ocr_lines=page["ocr_lines"],
            source_refs=refs,
            concept_ids=body.concept_ids,
            status="needs_confirmation",
            question_id=None,
            attempt_ids=[],
            variant_ids=[],
            error_cause="待校对与诊断",
            created_at=now(),
        ),
    )


def register(engine):
    def variant_job(job, payload):
        db, user, course = engine.db, job["user_id"], job["course_id"]
        mid = payload["mistake_id"]
        with db.transaction() as c:
            mistake = db.get(c, user, course, "mistake", mid)
            require(mistake["status"] == "confirmed", "MISTAKE_NOT_CONFIRMED", "请先校对错题", 409)
            question = db.get(c, user, course, "question", mistake["question_id"])
            concept = db.get(c, user, course, "concept", question["concept_ids"][0])
            kind = "numeric" if question["kind"] == "numeric" else "cloze"
            seen = {question["prompt"]}
            seen.update(db.get(c, user, course, "question", qid)["prompt"] for qid in mistake["variant_ids"])
            variants = []
            for index in range(payload["count"]):
                key = f"variant_{job['job_id']}_{index}"
                # Retry after a crash reuses already committed variants, preserving their exact questions.
                existing = next((q for q in db.list(c, user, course, "question") if q["id"] == key), None)
                if existing:
                    variants.append(existing["id"])
                    continue
                for retry in range(30):
                    data = generate(
                        concept,
                        kind,
                        question["difficulty"]["initial"],
                        payload["seed"] + retry,
                        index,
                        exclude=seen,
                    )
                    if data["prompt"] not in seen:
                        break
                require(
                    data["prompt"] not in seen, "INSUFFICIENT_VARIETY", "来源不足以继续生成不同的变式题", 422
                )
                data.update(parent_question_id=question["id"], mistake_id=mid)
                q = create_question(engine, c, user, course, data, key=key, origin="variant")
                variants.append(q["id"])
                seen.add(data["prompt"])
            mistake["variant_ids"] = list(dict.fromkeys(mistake["variant_ids"] + variants))
            db.put(c, user, course, "mistake", mistake)
        return {"type": "mistake_variants", "id": mid, "question_ids": variants}

    engine.queue.handlers["variant_generate"] = variant_job
