import io
import json
import os
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import pymupdf
import pytest
from conftest import api, attempt, finish, question
from fastapi.testclient import TestClient
from PIL import Image, ImageDraw, ImageFont

from backend.app import create_app
from backend.assessment import service as assessment_service
from backend.assessment import support
from backend.engine.config import Settings
from backend.engine.errors import DomainError
from backend.materials.parser import parse_file, structure

BASE = "/api/v1/courses/course-demo"
TEACHER = {"Authorization": "Bearer teacher-token"}


def teacher(client, courses=None, permissions=None):
    client.app.state.learning_engine.access.identities["teacher-token"] = dict(
        user_id="teacher",
        course_ids=courses or ["course-demo"],
        permissions=permissions if permissions is not None else ["content:write", "assessment:review"],
    )


def submit_session(client, qid, sid, key):
    return api(
        client,
        "post",
        "/attempts",
        json=dict(question_id=qid, practice_session_id=sid, answer="4"),
        headers={"Idempotency-Key": key},
    )


def test_reupload_and_legacy_duplicate_job_preserve_corrected_cited_source(client):
    payload = b"Original source text for correction."
    upload = api(
        client,
        "post",
        "/materials",
        files={"file": ("source.txt", payload)},
        headers={"Idempotency-Key": "first"},
    )
    finish(client, upload["job"])
    material = api(client, "get", "/materials/" + upload["material_id"])
    corrected = api(
        client,
        "patch",
        f"/materials/{material['id']}/chunks",
        json=dict(chunk_id=material["chunks"][0]["chunk_id"], text="Corrected and immutable source content."),
    )
    chunk = corrected["chunks"][0]
    ref = dict(
        material_id=material["id"],
        chunk_id=chunk["chunk_id"],
        page=1,
        quote=chunk["text"],
        start=chunk["start"],
        end=chunk["end"],
    )
    api(client, "post", "/knowledge/concepts", json=dict(title="Corrected source", source_refs=[ref]))
    again = api(
        client,
        "post",
        "/materials",
        files={"file": ("renamed.txt", payload)},
        headers={"Idempotency-Key": "second"},
    )
    assert again["job"]["job_id"] == upload["job"]["job_id"]
    assert api(client, "get", "/materials/" + material["id"]) == corrected
    # A queued task created by the previous release must also be safe to recover/retry.
    engine = client.app.state.learning_engine
    with engine.db.transaction() as c:
        old = engine.queue.enqueue(
            c,
            "user-demo",
            "course-demo",
            "material_parse",
            {"material_id": material["id"]},
            "legacy-duplicate",
        )
    finish(client, old)
    assert api(client, "get", "/materials/" + material["id"]) == corrected
    assert (
        client.post(
            BASE + "/materials",
            files={"file": ("other.txt", b"different")},
            headers={"Idempotency-Key": "second"},
        ).status_code
        == 409
    )
    api(client, "post", "/knowledge/concepts", json=dict(title="Still valid", source_refs=[ref]))


def test_solution_history_survives_new_and_preopened_sessions(client, content):
    q = question(client, content[1])
    before = [api(client, "post", f"/questions/{q['id']}/sessions") for _ in range(2)]
    api(
        client,
        "post",
        "/tutoring/ask",
        json=dict(question="求解", question_id=q["id"], practice_session_id=before[0]["id"], mode="solution"),
    )
    first = submit_session(client, q["id"], before[1]["id"], "preopened")
    others = [attempt(client, q["id"], "4", key=f"repeat-{i}") for i in range(3)]
    assert all(a["solution_viewed"] and a["evidence_weight"] == 0 for a in [first, *others])
    state = api(client, "get", "/mastery")["items"][0]
    assert state["independent_correct_count"] == 0 and state["status"] != "mastered"
    settings = Settings(
        data_dir=client.app.state.learning_engine.settings.data_dir, mode="demo", worker_enabled=False
    )
    with TestClient(create_app(settings)) as restarted:
        restarted.headers["Authorization"] = "Bearer demo-token"
        a = attempt(restarted, q["id"], "4", key="after-restart")
        assert a["solution_viewed"] and a["evidence_weight"] == 0


def test_hint_level_carries_across_sessions(client, content):
    q = question(client, content[1])
    s = api(client, "post", f"/questions/{q['id']}/sessions")
    api(
        client,
        "post",
        "/tutoring/ask",
        json=dict(
            question="提示", question_id=q["id"], practice_session_id=s["id"], mode="hint", hint_level=2
        ),
    )
    a = attempt(client, q["id"], "4", key="hint-new-session")
    assert not a["solution_viewed"] and a["evidence_weight"] == 0.6
    assert a["hint_records"][0]["level"] == 2


def test_same_question_feedback_cannot_be_farmed_but_delayed_recall_counts(client, content, monkeypatch):
    q = question(client, content[1])
    assert attempt(client, q["id"], "4", key="first")["evidence_weight"] == 1
    repeated = [attempt(client, q["id"], "4", key=f"repeat-{i}") for i in range(3)]
    assert all(a["evidence_weight"] == 0 for a in repeated)
    assert api(client, "get", "/mastery")["items"][0]["independent_correct_count"] == 1
    future = (datetime.now(timezone.utc) + timedelta(hours=25)).isoformat()
    monkeypatch.setattr(support, "now", lambda: future)
    monkeypatch.setattr(assessment_service, "now", lambda: future)
    delayed = attempt(client, q["id"], "4", key="next-day")
    assert not delayed["solution_viewed"] and delayed["evidence_weight"] == 1


def test_hint_sources_hide_cloze_answer_and_explicit_source_view_is_assisted(client, content):
    q = question(
        client, content[1], kind="cloze", prompt="____：只含一个未知数的方程。", answer="一元一次方程"
    )
    s = api(client, "post", f"/questions/{q['id']}/sessions")
    reply = api(
        client,
        "post",
        "/tutoring/ask",
        json=dict(
            question="提示", question_id=q["id"], practice_session_id=s["id"], mode="hint", hint_level=1
        ),
    )
    assert all("quote" not in ref for ref in reply["sources"])
    assert q["answer"] not in json.dumps(reply, ensure_ascii=False)
    opened = api(client, "post", f"/questions/{q['id']}/sources", json={"practice_session_id": s["id"]})
    assert opened["answer_exposed"] and any(q["answer"] in r["quote"] for r in opened["sources"])
    a = attempt(client, q["id"], q["answer"], key="after-source")
    assert a["solution_viewed"] and a["evidence_weight"] == 0


def test_separate_teacher_reviews_student_attempt_and_events_stay_with_student(client, content):
    teacher(client)
    q = question(client, content[1], kind="short_answer", answer="标准答案")
    a = attempt(client, q["id"], "用其他措辞给出推导过程", key="manual")
    queue = api(client, "get", "/assessment/review-queue", headers=TEACHER)["items"]
    assert queue[0]["user_id"] == "user-demo" and queue[0]["attempt_id"] == a["id"]
    graded = api(
        client,
        "post",
        f"/attempts/{a['id']}/grade",
        headers=TEACHER,
        json={"score": 1, "rationale": "已经完整说明推导步骤，符合全部评分要求。"},
    )
    assert graded["reviewed_by"] == "teacher" and graded["status"] == "graded"
    assert api(client, "get", "/mastery")["items"][0]["independent_correct_count"] == 1
    assert api(client, "get", "/mastery", headers=TEACHER)["items"] == []
    assert client.get("/api/v1/learning-events", headers=TEACHER).json()["items"] == []
    events = client.get("/api/v1/learning-events").json()["items"]
    assert events[-1]["user_id"] == "user-demo" and events[-1]["event_type"] == "practice_graded"
    assert api(client, "get", "/assessment/review-queue", headers=TEACHER)["items"] == []


def test_student_transcribes_and_separate_teacher_confirms_capture(client, content):
    teacher(client)
    material, con, _ = content
    m = api(client, "post", "/mistakes/capture", json={"material_id": material["id"], "original_answer": "5"})
    updated = api(client, "patch", f"/mistakes/{m['id']}/transcription", json={"text": "2x + 3 = 11，求 x。"})
    assert updated["original_question"] == m["original_question"] and updated["original_answer"] == "5"
    queue = api(client, "get", "/mistakes/review-queue", headers=TEACHER)["items"]
    assert queue[0]["corrected_question"] == updated["corrected_question"]
    assert con["id"] in {n["id"] for n in queue[0]["available_concepts"]}
    draft = dict(
        kind="numeric",
        prompt=updated["corrected_question"],
        answer="4",
        concept_ids=[con["id"]],
        source_refs=con["source_refs"],
        explanation="先减去3，再除以2。",
    )
    # Learner transcription does not grant the ability to author their own grading standard.
    assert client.post(BASE + f"/mistakes/{m['id']}/confirm", json={"question": draft}).status_code == 403
    confirmed = api(client, "post", f"/mistakes/{m['id']}/confirm", headers=TEACHER, json={"question": draft})
    assert confirmed["confirmed_by"] == "teacher" and confirmed["status"] == "confirmed"
    assert api(client, "get", "/questions/" + confirmed["question_id"])["prompt"] == draft["prompt"]
    assert client.get(BASE + f"/mistakes/{m['id']}", headers=TEACHER).status_code == 404
    api(client, "get", f"/mistakes/{m['id']}/explanation")
    after_explanation = attempt(client, confirmed["question_id"], "4", key="after-steps")
    assert after_explanation["solution_viewed"] and after_explanation["evidence_weight"] == 0


@pytest.mark.parametrize("role", ["student", "wrong-course", "revoked-student"])
def test_review_access_remains_role_and_course_scoped(client, content, role):
    teacher(client)
    q = question(client, content[1], kind="short_answer", answer="标准答案")
    a = attempt(client, q["id"], "需要审核的表述", key="pending")
    access = client.app.state.learning_engine.access
    headers = TEACHER
    if role == "student":
        teacher(client, permissions=[])
    elif role == "wrong-course":
        teacher(client, courses=["course-other"])
    else:
        for row in access.identities.values():
            if row["user_id"] == "user-demo":
                row["course_ids"] = []
    r = client.post(
        BASE + f"/attempts/{a['id']}/grade",
        headers=headers,
        json={"score": 1, "rationale": "审核内容完整且满足全部评分要点。"},
    )
    assert r.status_code == 403


def test_exam_retry_reuses_original_revision_and_conflicts_on_changed_request(client, content):
    body = {"slots": [{"concept_id": content[1]["id"], "count": 1, "kind": "numeric"}]}
    bp = api(client, "post", "/exam-blueprints", json=body)
    req = {"blueprint_id": bp["id"], "seed": 4}
    headers = {"Idempotency-Key": "same-exam"}
    job = api(client, "post", "/exams", json=req, headers=headers)
    body["slots"][0]["count"] = 2
    api(client, "put", "/exam-blueprints/" + bp["id"], json=body)
    assert api(client, "post", "/exams", json=req, headers=headers)["job_id"] == job["job_id"]
    assert client.post(BASE + "/exams", json=dict(req, seed=5), headers=headers).status_code == 409
    eid = finish(client, job)["id"]
    assert len(api(client, "get", "/exams/" + eid)["items"]) == 1
    assert api(client, "post", "/exams", json=req, headers=headers)["job_id"] == job["job_id"]


def test_legacy_exam_job_retry_survives_blueprint_edit(client, content):
    body = {"slots": [{"concept_id": content[1]["id"], "count": 1, "kind": "numeric"}]}
    bp = api(client, "post", "/exam-blueprints", json=body)
    engine = client.app.state.learning_engine
    with engine.db.transaction() as c:
        snapshot = dict(bp, id=bp["id"] + "_r1")
        engine.db.put(c, "user-demo", "course-demo", "blueprint", snapshot)
        old = engine.queue.enqueue(
            c,
            "user-demo",
            "course-demo",
            "exam_generate",
            dict(blueprint_id=snapshot["id"], seed=42),
            "old-exam",
        )
    api(client, "put", "/exam-blueprints/" + bp["id"], json=body)
    again = api(
        client, "post", "/exams", json={"blueprint_id": bp["id"]}, headers={"Idempotency-Key": "old-exam"}
    )
    assert again["job_id"] == old["job_id"]


def mixed_pdf(tmp_path, full_page=False):
    image = Image.new("RGB", (900, 600), "white")
    draw = ImageDraw.Draw(image)
    draw.text(
        (40, 80),
        "一元一次方程：2x + 3 = 11",
        fill="black",
        font=ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 36),
    )
    stream = io.BytesIO()
    image.save(stream, format="PNG")
    target = tmp_path / "mixed.pdf"
    with pymupdf.open() as doc:
        page = doc.new_page()
        page.insert_image(
            page.rect if full_page else pymupdf.Rect(40, 40, 540, 700),
            stream=stream.getvalue(),
            keep_proportion=not full_page,
        )
        if full_page:
            page.insert_text((40, 30), "Course material native header")
        page.insert_text((40, 800), "Course material footer - page 1")
        doc.save(target)
    return target


@pytest.mark.parametrize("full_page", [False, True])
def test_scanned_body_with_native_footer_is_ocrd_and_retains_footer(tmp_path, monkeypatch, full_page):
    calls = []

    def ocr(image):
        calls.append(image.size)
        return [dict(text="一元一次方程：2x + 3 = 11", confidence=1, bbox=[])]

    monkeypatch.setattr("backend.materials.parser.ocr_image", ocr)
    pages = parse_file(mixed_pdf(tmp_path, full_page=full_page))
    assert calls and "2x + 3 = 11" in pages[0]["text"] and "footer" in pages[0]["text"]
    assert pages[0]["method"] == "pdf_text_ocr"
    if full_page:
        assert "header" in pages[0]["text"]
    chunks, _ = structure("mixed", pages)
    assert all(ch["needs_confirmation"] for ch in chunks)
    assert all(pages[0]["text"][ch["start"] : ch["end"]] == ch["text"] for ch in chunks)


def test_native_text_pdf_keeps_fast_path(tmp_path, monkeypatch):
    target = tmp_path / "native.pdf"
    with pymupdf.open() as doc:
        page = doc.new_page()
        page.insert_text((40, 80), "Native course content with sufficient extractable text.")
        doc.save(target)
    monkeypatch.setattr("backend.materials.parser.ocr_image", lambda _: pytest.fail("Unexpected OCR"))
    assert parse_file(target)[0]["method"] == "pdf_text"


@pytest.mark.skipif(os.getenv("ZHUOZHI_TEST_OCR") != "true", reason="Real OCR integration")
def test_mixed_pdf_real_chinese_ocr(tmp_path):
    page = parse_file(mixed_pdf(tmp_path))[0]
    assert page["method"] == "pdf_text_ocr" and "方程" in page["text"] and "11" in page["text"]
    assert "footer" in page["text"] and page["ocr_lines"]


def test_slow_model_does_not_block_unrelated_attempt(client, content):
    q = question(client, content[1])
    s = api(client, "post", f"/questions/{q['id']}/sessions")
    entered, release = threading.Event(), threading.Event()

    class Model:
        enabled = True

        def explain(self, query, mode, hits):
            entered.set()
            assert release.wait(8)
            return "教材讲解", [hits[0]["source"]]

    client.app.state.learning_engine.model = Model()
    with ThreadPoolExecutor(max_workers=2) as pool:
        future = pool.submit(client.post, BASE + "/tutoring/ask", json={"question": "一元一次方程"})
        try:
            assert entered.wait(5)
            writer = pool.submit(submit_session, client, q["id"], s["id"], "during-model")
            assert writer.result(timeout=3)["score"] == 1
        finally:
            release.set()
        assert future.result(timeout=5).status_code == 200


def test_model_error_does_not_leave_partial_reply(client, content):
    class Model:
        enabled = True

        def explain(self, query, mode, hits):
            raise DomainError("MODEL_UNAVAILABLE", "测试模型不可用", 503, True)

    engine = client.app.state.learning_engine
    engine.model = Model()
    assert client.post(BASE + "/tutoring/ask", json={"question": "一元一次方程"}).status_code == 503
    with engine.db.connect() as c:
        assert engine.db.list(c, "user-demo", "course-demo", "tutoring_reply") == []
