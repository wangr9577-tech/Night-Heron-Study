import pymupdf
from conftest import api, attempt, finish
from pptx import Presentation


def test_full_exam_mistake_variant_review_events(client, content):
    material, concept, mean = content
    original = api(
        client,
        "post",
        "/materials",
        files={"file": ("original.txt", "1. 一元一次方程（10分）\n2. 算术平均数（10分）".encode())},
    )
    finish(client, original["job"])
    analysis = api(client, "post", "/exams/analyze", json={"material_id": original["material_id"]})
    assert len(analysis["parsed_questions"]) == 2
    bp = api(
        client,
        "post",
        "/exam-blueprints",
        json={
            "slots": [
                {"concept_id": concept["id"], "count": 2, "kind": "numeric"},
                {"concept_id": mean["id"], "count": 1, "kind": "numeric"},
            ]
        },
    )
    job = api(
        client,
        "post",
        "/exams",
        json={"blueprint_id": bp["id"], "seed": 22},
        headers={"Idempotency-Key": "exam1"},
    )
    ref = finish(client, job)
    exam = api(client, "get", "/exams/" + ref["id"])
    assert len({q["prompt"] for q in exam["questions"]}) == 3
    assert "answer" not in exam["questions"][0]
    paper = client.get(f"/api/v1/courses/course-demo/exams/{exam['id']}/paper")
    answers = client.get(
        f"/api/v1/courses/course-demo/exams/{exam['id']}/answers",
        headers={"Authorization": "Bearer author-token"},
    )
    with pymupdf.open(stream=paper.content, filetype="pdf") as pdf:
        assert len(pdf) >= 1 and "参考答案" not in "".join(p.get_text() for p in pdf)
    with pymupdf.open(stream=answers.content, filetype="pdf") as pdf:
        assert "答案" in "".join(p.get_text() for p in pdf)
    qid = exam["questions"][0]["id"]
    wrong = attempt(client, qid, "-999", exam_id=exam["id"], source_task_id="task-from-A")
    assert wrong["score"] == 0 and wrong["grading_rationale"]
    mistakes = api(client, "get", "/mistakes")["items"]
    assert len(mistakes) == 1 and wrong["id"] in mistakes[0]["attempt_ids"]
    mid = mistakes[0]["id"]
    job = api(client, "post", f"/mistakes/{mid}/variants", json={"count": 2})
    variants = finish(client, job)["question_ids"]
    assert len(variants) == 2
    answer_key = api(
        client,
        "get",
        f"/questions/{variants[0]}/answer-key",
        headers={"Authorization": "Bearer author-token"},
    )
    correct = attempt(
        client, variants[0], answer_key["answer"], key="variant-a", source_task_id="task-from-A"
    )
    assert correct["score"] == 1
    detail = api(client, "get", "/mistakes/" + mid)
    assert len(detail["attempts"]) == 2
    explanation = api(client, "get", f"/mistakes/{mid}/explanation")
    assert all(step["highlight_element_ids"] for step in explanation["steps"])
    review = next(r for r in api(client, "get", "/reviews")["items"] if r["question_id"] == qid)
    answer_key = api(
        client, "get", f"/questions/{qid}/answer-key", headers={"Authorization": "Bearer author-token"}
    )
    revision = attempt(client, qid, answer_key["answer"], key="review-a", review_id=review["id"])
    rated = api(
        client, "post", f"/reviews/{review['id']}/rate", json={"attempt_id": revision["id"], "quality": 2}
    )
    again = api(
        client, "post", f"/reviews/{review['id']}/rate", json={"attempt_id": revision["id"], "quality": 2}
    )
    assert revision["solution_viewed"] and revision["evidence_weight"] == 0
    assert rated == again and rated["repetitions"] == 0 and rated["interval_days"] == 1
    snapshot = api(client, "get", "/learning-snapshot")
    assert snapshot["state_version"] > 0 and snapshot["concept_states"][0]["evidence_ids"]
    first = client.get("/api/v1/learning-events?limit=2").json()
    assert first["has_more"]
    assert client.get("/api/v1/learning-events?limit=2").json() == first
    second = client.get("/api/v1/learning-events?cursor=" + first["next_cursor"]).json()
    assert not {e["event_id"] for e in first["items"]} & {e["event_id"] for e in second["items"]}
    assert all(e["result"]["task_requirement_met"] is None for e in first["items"] + second["items"])


def test_lesson_real_pptx_roundtrip_player_position(client, content):
    _, concept, mean = content
    before = api(client, "get", "/mastery")
    job = api(
        client, "post", "/lessons", json={"title": "代数基础", "concept_ids": [concept["id"], mean["id"]]}
    )
    lid = finish(client, job)["id"]
    lesson = api(client, "get", "/lessons/" + lid)
    response = client.get(f"/api/v1/courses/course-demo/lessons/{lid}/pptx")
    import io

    deck = Presentation(io.BytesIO(response.content))
    from zipfile import ZipFile

    with ZipFile(io.BytesIO(response.content)) as package:
        assert b"Microsoft YaHei" in package.read("ppt/slides/slide1.xml")
    assert len(deck.slides) == len(lesson["pages"])
    for page, slide in zip(lesson["pages"], deck.slides, strict=True):
        slide_text = "\n".join(s.text for s in slide.shapes if s.has_text_frame)
        for element in page["elements"]:
            assert element["text"] in slide_text
        ids = {element["element_id"] for element in page["elements"]}
        assert all(set(seg["highlight_element_ids"]) <= ids for seg in page["narration_segments"])
    page = lesson["pages"][0]
    position = dict(
        page_id=page["page_id"], segment_id=page["narration_segments"][0]["segment_id"], offset_seconds=12.5
    )
    api(client, "put", f"/lessons/{lid}/position", json=position)
    assert api(client, "get", f"/lessons/{lid}/position")["offset_seconds"] == 12.5
    assert before == api(client, "get", "/mastery")
    # Feed a genuinely generated PPTX back to B1 to validate the parser with the same source material.
    uploaded = api(client, "post", "/materials", files={"file": ("lesson.pptx", response.content)})
    finish(client, uploaded["job"])
    material = api(client, "get", "/materials/" + uploaded["material_id"])
    assert len(material["pages"]) == len(lesson["pages"])


def test_capture_requires_confirmation(client, content):
    client.app.state.learning_engine.access.identities["reviewer-token"] = {
        "user_id": "reviewer", "course_ids": ["course-demo"], "permissions": ["content:write"]
    }
    material, concept, _ = content
    captured = api(
        client, "post", "/mistakes/capture", json={"material_id": material["id"], "original_answer": "5"}
    )
    assert captured["status"] == "needs_confirmation"
    assert (
        client.post(
            f"/api/v1/courses/course-demo/mistakes/{captured['id']}/variants", json={"count": 1}
        ).status_code
        == 409
    )
    q = dict(
        kind="numeric",
        prompt="2x+3=11，求 x。",
        answer="4",
        concept_ids=[concept["id"]],
        source_refs=concept["source_refs"],
        explanation="两边减去3，再除以2。",
    )
    confirmed = api(
        client,
        "post",
        f"/mistakes/{captured['id']}/confirm",
        json={"question": q, "error_cause": "移项错误"},
        headers={"Authorization": "Bearer reviewer-token"},
    )
    assert confirmed["original_answer"] == "5" and confirmed["corrected_question"] == q["prompt"]
