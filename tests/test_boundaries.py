from conftest import SOURCE, api, finish, question


def test_access_scope_on_all_business_modules(client, content):
    material, con, _ = content
    q = question(client, con)
    for route in [
        "/materials",
        "/materials/" + material["id"],
        "/knowledge",
        "/lessons",
        "/exam-blueprints/x",
        "/exams",
        "/mistakes",
        "/questions/" + q["id"],
        "/mastery",
        "/reviews",
        "/learning-snapshot",
        "/jobs",
    ]:
        r = client.get("/api/v1/courses/course-demo" + route, headers={"Authorization": "Bearer other-token"})
        assert r.status_code == 403, (route, r.text)
    assert (
        client.get(
            "/api/v1/courses/course-demo/materials", headers={"Authorization": "Bearer unknown"}
        ).status_code
        == 401
    )
    assert (
        client.get("/api/v1/courses/course-demo/materials", headers={"Authorization": ""}).status_code == 401
    )
    assert (
        client.get("/api/v1/learning-events", headers={"Authorization": "Bearer other-token"}).json()["items"]
        == []
    )


def test_shared_course_still_user_isolated_and_external_access_called(client, content):
    from backend.engine.access import Identity
    from backend.engine.errors import require

    material, _, _ = content
    calls = []

    class Access:
        def authenticate(self, token):
            return Identity("second-user", ("course-demo",))

        def require_course_access(self, user, course):
            calls.append((user, course))
            require(course == "course-demo", "COURSE_FORBIDDEN", "denied", 403)

    client.app.state.learning_engine.access = Access()
    assert api(client, "get", "/materials")["items"] == []
    assert client.get("/api/v1/courses/course-demo/materials/" + material["id"]).status_code == 404
    assert len(calls) >= 2


def test_graph_source_integrity_dedup_and_cycles(client, content):
    material, one, two = content
    again = api(client, "post", "/knowledge/extract", json={"material_ids": [material["id"]]})
    graph = api(client, "get", "/knowledge")
    assert len(graph["nodes"]) == len(again["nodes"])
    edge = dict(from_id=one["id"], to_id=two["id"], type="prerequisite")
    api(client, "post", "/knowledge/edges", json=edge)
    r = client.post(
        "/api/v1/courses/course-demo/knowledge/edges",
        json=dict(from_id=two["id"], to_id=one["id"], type="prerequisite"),
    )
    assert r.status_code == 422 and r.json()["error"]["code"] == "GRAPH_CYCLE"
    ref = dict(one["source_refs"][0], quote="不存在的原文")
    bad = client.post(
        "/api/v1/courses/course-demo/knowledge/concepts", json={"title": "假知识点", "source_refs": [ref]}
    )
    assert bad.status_code == 422
    snapshot = api(client, "get", "/learning-snapshot")
    assert not any(c["target_id"] == two["id"] for c in snapshot["candidates"])


def test_grounded_search_quote_and_no_fabrication(client, content):
    material, _, _ = content
    reply = api(client, "post", "/tutoring/ask", json={"question": "一元一次方程如何求解"})
    assert reply["grounded"] and reply["sources"]
    for ref in reply["sources"]:
        page = material["pages"][ref["page"] - 1]["text"]
        assert page[ref["start"] : ref["end"]] == ref["quote"]
    no = api(client, "post", "/tutoring/ask", json={"question": "quantum chromodynamics"})
    assert not no["grounded"] and no["sources"] == []


def test_jobs_dedup_failure_retry_recovery_and_immutable_request(client, content):
    engine = client.app.state.learning_engine
    with engine.db.transaction() as c:
        j = engine.queue.enqueue(c, "user-demo", "course-demo", "transient_test", {}, "retry")
    from backend.engine.errors import DomainError

    def transient(job, payload):
        raise DomainError("TEMPORARY_TEST", "temporary", 503, True)

    engine.queue.handlers["transient_test"] = transient
    engine.queue.run_one()
    failed = api(client, "get", "/jobs/" + j["job_id"])
    assert failed["status"] == "failed" and failed["retryable"]
    engine.queue.handlers["transient_test"] = lambda job, payload: {"type": "test", "id": "ok"}
    api(client, "post", "/jobs/" + j["job_id"] + "/retry")
    finish(client, j)
    assert api(client, "get", "/jobs/" + j["job_id"])["attempts"] == 2
    r = api(
        client,
        "post",
        "/materials",
        files={"file": ("same.md", SOURCE.encode())},
        headers={"Idempotency-Key": "same"},
    )
    r2 = api(
        client,
        "post",
        "/materials",
        files={"file": ("same.md", SOURCE.encode())},
        headers={"Idempotency-Key": "same"},
    )
    assert r == r2
    conflict = client.post(
        "/api/v1/courses/course-demo/materials",
        files={"file": ("same.md", b"changed")},
        headers={"Idempotency-Key": "same"},
    )
    assert conflict.status_code == 409
    with engine.db.transaction() as c:
        c.execute(
            "UPDATE b_jobs SET status='running',lease_until='2000-01-01' WHERE job_id=?",
            (r["job"]["job_id"],),
        )
    finish(client, r["job"])


def test_validation_no_answer_leak_and_source_lock(client, content):
    material, con, _ = content
    q = question(client, con)
    public = api(client, "get", "/questions/" + q["id"])
    assert "answer" not in public and "quote" not in public["source_refs"][0] and "verification" not in public
    assert client.get(f"/api/v1/courses/course-demo/questions/{q['id']}/answer-key").status_code == 403
    assert (
        client.post("/api/v1/courses/course-demo/materials", files={"file": ("bad.exe", b"bad")}).status_code
        == 415
    )
    assert (
        client.post("/api/v1/courses/course-demo/materials", files={"file": ("empty.pdf", b"")}).status_code
        == 422
    )
    assert client.get("/api/v1/learning-events?cursor=-1").status_code == 422
    assert client.get("/api/v1/learning-events?cursor=9999999999999999999999").status_code == 422
    assert (
        client.patch(
            "/api/v1/courses/course-demo/materials/" + material["id"] + "/chunks",
            json={"chunk_id": material["chunks"][0]["chunk_id"], "text": "修改"},
        ).status_code
        == 409
    )


def test_blueprint_version_frozen_during_queue(client, content):
    _, con, _ = content
    body = {"slots": [{"concept_id": con["id"], "count": 1, "kind": "numeric"}]}
    bp = api(client, "post", "/exam-blueprints", json=body)
    job = api(client, "post", "/exams", json={"blueprint_id": bp["id"]})
    body["slots"][0]["count"] = 3
    api(client, "put", "/exam-blueprints/" + bp["id"], json=body)
    exam = api(client, "get", "/exams/" + finish(client, job)["id"])
    assert len(exam["items"]) == 1 and exam["blueprint_revision"] == 1
