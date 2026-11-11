from fastapi.testclient import TestClient

from backend.app import core, main


def test_http_auth_planner_and_permissions(tmp_path, monkeypatch):
    monkeypatch.setattr(core, "DB_PATH", tmp_path / "http.db")
    core.init_core()
    from backend.app.extra import init_extra

    init_extra()
    from backend.app.demo_b import init_demo_b

    init_demo_b()
    with TestClient(main.app) as client:
        assert client.get("/api/v1/courses").status_code == 401
        a = client.post("/api/v1/auth/register", json={"username": "alice", "password": "password"}).json()
        b = client.post("/api/v1/auth/register", json={"username": "bob", "password": "password"}).json()
        ah = {"Authorization": "Bearer " + a["access_token"]}
        bh = {"Authorization": "Bearer " + b["access_token"]}
        course = client.post("/api/v1/courses", headers=ah, json={"title": "数学"}).json()
        cid = course["course_id"]
        for invalid in (
            {"ddl": 123},
            {"available_slots": [123]},
            {"available_slots": [{"weekday": 1, "start": "20:00", "end": "19:00"}]},
        ):
            assert client.patch(f"/api/v1/courses/{cid}", headers=ah, json=invalid).status_code == 400
        assert (
            client.post(
                "/api/v1/courses", headers=ah, json={"title": "bad", "available_slots": [1]}
            ).status_code
            == 400
        )
        response = client.get(f"/api/v1/courses/{cid}", headers=bh)
        assert response.status_code == 403 and response.json()["error_code"] == "no_course_access"
        response = client.post(
            f"/api/v1/courses/{cid}/planner/tasks",
            headers=ah,
            json={"type": "practice", "target_id": "qst_1", "title": "练习", "planned_date": "2026-11-06"},
        )
        assert response.status_code == 200
        tid = response.json()["task_id"]
        assert client.get(f"/api/v1/planner/tasks/{tid}", headers=bh).status_code == 404
        assert (
            client.post(
                f"/api/v1/planner/tasks/{tid}/complete", headers=ah, json={"completion": "full"}
            ).status_code
            == 422
        )
        snapshot = client.get(f"/api/v1/courses/{cid}/learning-snapshot", headers=ah)
        assert snapshot.status_code == 200 and snapshot.json()["candidates"] == []
        assert client.get(f"/api/v1/courses/{cid}/planner/candidates", headers=ah).json()["items"] == []
        assert client.get("/api/v1/learning-events", headers=ah).json()["items"] == []
        assert client.post("/api/v1/auth/logout", headers=ah).status_code == 200
        assert client.get("/api/v1/users/me", headers=ah).status_code == 401
