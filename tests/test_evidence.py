from concurrent.futures import ThreadPoolExecutor

from conftest import api, attempt, question


def test_attempt_idempotency_and_no_duplicate_evidence(client, content):
    _, con, _ = content
    q = question(client, con)
    session = api(client, "post", f"/questions/{q['id']}/sessions")
    body = dict(question_id=q["id"], answer="4", practice_session_id=session["id"])

    def submit():
        return api(client, "post", "/attempts", json=body, headers={"Idempotency-Key": "concurrent"})

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: submit(), range(4)))
    assert len({r["id"] for r in results}) == 1
    states = api(client, "get", "/mastery")["items"]
    assert states[0]["graded_count"] == 1 and len(states[0]["evidence_ids"]) == 1
    events = client.get("/api/v1/learning-events").json()["items"]
    assert len(events) == 2
    body["answer"] = "5"
    r = client.post(
        "/api/v1/courses/course-demo/attempts", json=body, headers={"Idempotency-Key": "concurrent"}
    )
    assert r.status_code == 409


def test_hints_server_recorded_and_solution_not_mastery(client, content):
    _, con, _ = content
    q = question(client, con)
    s = api(client, "post", f"/questions/{q['id']}/sessions")
    hint = api(
        client,
        "post",
        "/tutoring/ask",
        json={
            "question": "怎么解方程",
            "question_id": q["id"],
            "practice_session_id": s["id"],
            "mode": "hint",
            "hint_level": 1,
        },
    )
    assert "参考答案" not in hint["answer"]
    api(
        client,
        "post",
        "/tutoring/ask",
        json={
            "question": "怎么解方程",
            "question_id": q["id"],
            "practice_session_id": s["id"],
            "mode": "solution",
        },
    )
    a = api(
        client,
        "post",
        "/attempts",
        json={"question_id": q["id"], "practice_session_id": s["id"], "answer": "4"},
        headers={"Idempotency-Key": "hinted"},
    )
    assert a["evidence_weight"] == 0 and len(a["hint_records"]) == 2
    state = api(client, "get", "/mastery")["items"][0]
    assert state["alpha"] == 1 and state["mastery"] == 0.5 and state["status"] != "mastered"
    illegal = client.post(
        "/api/v1/courses/course-demo/attempts",
        json={"question_id": q["id"], "practice_session_id": s["id"], "answer": "4", "hint_records": []},
    )
    assert illegal.status_code == 422


def test_subjective_pending_review_has_no_mastery_then_manual_once(client, content):
    _, con, _ = content
    q = question(client, con, kind="short_answer", answer="等式两边同时减去常数项，再除以非零系数")
    a = attempt(client, q["id"], "先将常数移到右边，然后化系数为一")
    assert a["status"] == "pending_review" and api(client, "get", "/mastery")["items"] == []
    route = f"/api/v1/courses/course-demo/attempts/{a['id']}/grade"
    assert client.post(route, json={"score": 1, "rationale": "正确说明移项与化系数过程。"}).status_code == 403
    client.app.state.learning_engine.access.identities["reviewer-token"] = {
        "user_id": "reviewer", "course_ids": ["course-demo"], "permissions": ["assessment:review"]
    }
    approved = client.post(
        route,
        json={"score": 1, "rationale": "正确说明移项与化系数过程。"},
        headers={"Authorization": "Bearer reviewer-token"},
    )
    assert approved.status_code == 200 and approved.json()["score"] == 1
    assert (
        client.post(
            route,
            json={"score": 1, "rationale": "正确说明移项与化系数过程。"},
            headers={"Authorization": "Bearer reviewer-token"},
        ).status_code
        == 409
    )


def test_transaction_rollback_does_not_publish_partial_learning_event(client, content, monkeypatch):
    _, con, _ = content
    q = question(client, con)
    engine = client.app.state.learning_engine
    from backend.review import service

    def fail(*args, **kwargs):
        raise RuntimeError("simulated transaction failure")

    monkeypatch.setattr(service, "ensure_review", fail)
    session = api(client, "post", f"/questions/{q['id']}/sessions")
    import pytest

    with pytest.raises(RuntimeError):
        api(
            client,
            "post",
            "/attempts",
            json={"question_id": q["id"], "answer": "4", "practice_session_id": session["id"]},
            headers={"Idempotency-Key": "rollback"},
        )
    with engine.db.connect() as c:
        for kind in ["attempt", "mastery", "review"]:
            assert engine.db.list(c, "user-demo", "course-demo", kind) == []
    assert client.get("/api/v1/learning-events").json()["items"] == []
