import json
import re

from backend.assessment.questions import create_question
from backend.engine.db import now, uid
from backend.engine.errors import require

from .export import render_exam
from .generator import generate


def validate_blueprint(engine, c, user, course, data):
    require(sum(slot["count"] for slot in data["slots"]) <= 50, "QUESTION_LIMIT", "试卷最多 50 题", 422)
    for slot in data["slots"]:
        engine.db.get(c, user, course, "concept", slot["concept_id"])
    return data


def analyze(engine, c, user, course, mid):
    material = engine.db.get(c, user, course, "material", mid)
    require(material["status"] == "ready", "MATERIAL_NOT_READY", "原卷尚未解析完成", 409)
    text = "\n".join(page["text"] for page in material["pages"])
    # Numbered questions remain drafts until the blueprint is explicitly confirmed/edited.
    matches = list(re.finditer(r"(?m)^\s*(?:第\s*)?(\d+)\s*[.、．)]\s*", text))
    parsed = []
    concepts = engine.db.list(c, user, course, "concept")
    for i, match in enumerate(matches):
        prompt = text[match.end() : matches[i + 1].start() if i + 1 < len(matches) else len(text)].strip()
        if not prompt:
            continue
        aligned = [con["id"] for con in concepts if con["title"] in prompt]
        points = re.search(r"[（(]\s*(\d+(?:\.\d+)?)\s*分\s*[)）]", prompt)
        parsed.append(
            dict(
                number=int(match.group(1)),
                prompt=prompt,
                concept_ids=aligned,
                points=float(points.group(1)) if points else None,
                needs_confirmation=True,
            )
        )
    slots = []
    for con in concepts:
        count = sum(con["id"] in q["concept_ids"] for q in parsed)
        if count:
            slots.append(
                dict(concept_id=con["id"], count=count, kind="cloze", difficulty="medium", points=10)
            )
    return engine.db.put(
        c,
        user,
        course,
        "exam_analysis",
        dict(
            id=uid("analysis"),
            material_id=mid,
            parsed_questions=parsed,
            suggested_slots=slots,
            requires_confirmation=True,
            warnings=[] if parsed else ["未识别到编号题目，请人工编辑蓝图"],
            created_at=now(),
        ),
    )


def register(engine):
    def exam_job(job, payload):
        db, user, course = engine.db, job["user_id"], job["course_id"]
        eid = "exam_" + job["job_id"]
        with db.transaction() as c:
            bp = db.get(c, user, course, "blueprint", payload["blueprint_id"])
            validate_blueprint(engine, c, user, course, bp)
            items, question_map, seen = [], {}, set()
            for slot in bp["slots"]:
                concept = db.get(c, user, course, "concept", slot["concept_id"])
                for _ in range(slot["count"]):
                    data = None
                    # Reject duplicated prompts within an exam even when numerical seeds collide.
                    for retry in range(30):
                        data = generate(
                            concept,
                            slot["kind"],
                            slot["difficulty"],
                            payload["seed"] + retry,
                            len(items),
                            exclude=seen,
                        )
                        if data["prompt"] not in seen:
                            break
                    require(
                        data["prompt"] not in seen, "INSUFFICIENT_VARIETY", "无法生成足够的不重复题目", 422
                    )
                    seen.add(data["prompt"])
                    question = dict(data, id=f"{eid}_q{len(items) + 1}")
                    question_map[question["id"]] = question
                    items.append(dict(question_id=question["id"], points=slot["points"]))
        exam = dict(
            id=eid,
            title=bp["title"],
            blueprint_id=bp["id"],
            blueprint_revision=bp["revision"],
            blueprint_snapshot=bp,
            duration_minutes=bp["duration_minutes"],
            items=items,
            total_points=sum(item["points"] for item in items),
            seed=payload["seed"],
            paper_filename=eid + "-paper.pdf",
            answers_filename=eid + "-answers.pdf",
            created_at=now(),
        )
        render_exam(exam["title"], items, question_map, engine.files / exam["paper_filename"])
        render_exam(exam["title"], items, question_map, engine.files / exam["answers_filename"], answers=True)
        (engine.files / (eid + ".json")).write_text(
            json.dumps(dict(exam=exam, questions=list(question_map.values())), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        with db.transaction() as c:
            for qid, data in question_map.items():
                create_question(engine, c, user, course, data, key=qid, origin="exam")
            db.put(c, user, course, "exam", exam)
        return {"type": "exam", "id": eid}

    engine.queue.handlers["exam_generate"] = exam_job
