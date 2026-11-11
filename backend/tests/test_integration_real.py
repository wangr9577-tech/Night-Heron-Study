"""Integration tests exercise A identities and scheduling against real B evidence."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from backend.app import core, main
from backend.app.extra import init_extra
from backend.app.integration import AppAccess
from backend.engine.config import Settings
from backend.engine.service import LearningEngine


@pytest.fixture
def integrated(tmp_path, monkeypatch):
    monkeypatch.setattr(core, "DB_PATH", tmp_path / "a.sqlite3")
    monkeypatch.delenv("ZHI_B_BASE_URL", raising=False)
    core.init_core()
    init_extra()
    learning = LearningEngine(
        Settings(data_dir=tmp_path / "b", mode="integrated", worker_enabled=False), AppAccess()
    )
    from backend.exams import service as exams
    from backend.lessons import service as lessons
    from backend.materials import service as materials
    from backend.mistakes import service as mistakes

    for module in (materials, lessons, exams, mistakes):
        module.register(learning)
    original = main.app.state.learning_engine
    main.app.state.learning_engine = learning
    with TestClient(main.app) as c:
        response = c.post("/api/v1/auth/register", json={"username": "learner", "password": "password"})
        c.headers["Authorization"] = "Bearer " + response.json()["access_token"]
        today = datetime.now(timezone(timedelta(hours=8))).date()
        course = c.post(
            "/api/v1/courses",
            json={
                "title": "测试课程",
                "ddl": str(today + timedelta(days=10)),
                "available_slots": [{"weekday": i, "start": "08:00", "end": "23:00"} for i in range(1, 8)],
            },
        ).json()
        cid = course["course_id"]
        r = c.post(
            "/api/v1/materials",
            data={"course_id": cid},
            files={
                "file": (
                    "course.md",
                    "# 算术平均数\n\n算术平均数：全部观测值的总和除以观测值个数。".encode(),
                    "text/markdown",
                )
            },
        )
        assert r.status_code == 202, r.text
        job = r.json()["job_id"]
        assert learning.queue.run_one()
        assert c.get("/api/v1/jobs/" + job).json()["status"] == "succeeded"
        g = c.post(
            f"/api/v1/courses/{cid}/knowledge/extract", json={"material_ids": [r.json()["material_id"]]}
        )
        assert g.status_code == 200, g.text
        concept = next(x for x in g.json()["nodes"] if x["title"] == "算术平均数")
        from backend.assessment.questions import create_question
        from backend.exams.generator import generate

        with learning.db.transaction() as db:
            q = create_question(
                learning,
                db,
                response.json()["user"]["user_id"],
                cid,
                generate(concept, "numeric", "easy", 42),
                origin="test_fixture",
            )
        yield c, cid, q, learning
    main.app.state.learning_engine = original


def test_real_task_grade_reward_idempotence_and_access(integrated):
    c, cid, q, learning = integrated
    candidates = c.get(f"/api/v1/courses/{cid}/planner/candidates").json()["items"]
    candidate = next(x for x in candidates if x["target_id"] == q["id"])
    today = datetime.now(timezone(timedelta(hours=8))).date().isoformat()
    task = c.post(
        f"/api/v1/courses/{cid}/planner/accept-recommendation",
        json={"candidate_id": candidate["candidate_id"], "planned_date": today},
    ).json()
    tid = task["task_id"]
    assert c.post(f"/api/v1/planner/tasks/{tid}/complete", json={"completion": "full"}).status_code == 422
    session = c.post(f"/api/v1/courses/{cid}/questions/{q['id']}/sessions").json()
    body = {
        "question_id": q["id"],
        "answer": q["answer"],
        "practice_session_id": session["id"],
        "source_task_id": tid,
    }
    result = c.post(f"/api/v1/courses/{cid}/attempts", json=body, headers={"Idempotency-Key": "one"})
    assert result.status_code == 201, result.text
    assert result.json()["score"] == 1
    with ThreadPoolExecutor(max_workers=3) as pool:
        results = list(
            pool.map(lambda _: c.post("/api/v1/rewards/consume-events", json={"course_id": cid}), range(3))
        )
    assert all(r.status_code == 200 for r in results), [(r.status_code, r.text) for r in results]
    assert c.get("/api/v1/rewards/points").json()["balance"] == 25
    assert c.get(f"/api/v1/planner/tasks/{tid}").json()["status"] == "done"
    pet = c.post("/api/v1/companion/pets", json={}).json()["pet_id"]
    with ThreadPoolExecutor(max_workers=2) as pool:
        bought = list(
            pool.map(
                lambda _: c.post(
                    "/api/v1/rewards/exchange",
                    headers={"Idempotency-Key": "buy-once"},
                    json={"item_id": "itm_apple", "qty": 1},
                ),
                range(2),
            )
        )
    assert all(x.status_code == 200 for x in bought)
    assert bought[0].json()["tx"]["tx_id"] == bought[1].json()["tx"]["tx_id"]
    assert c.get("/api/v1/rewards/points").json()["balance"] == 15
    fed = c.post(
        "/api/v1/rewards/feed",
        headers={"Idempotency-Key": "feed-once"},
        json={"pet_id": pet, "item_id": "itm_apple"},
    )
    again = c.post(
        "/api/v1/rewards/feed",
        headers={"Idempotency-Key": "feed-once"},
        json={"pet_id": pet, "item_id": "itm_apple"},
    )
    assert (
        fed.status_code == 200
        and again.json()["growth_event"]["event_id"] == fed.json()["growth_event"]["event_id"]
    )
    conflict = c.post(
        "/api/v1/rewards/exchange",
        headers={"Idempotency-Key": "buy-once"},
        json={"item_id": "itm_apple", "qty": 2},
    )
    assert conflict.status_code == 409

    assert (
        c.post(f"/api/v1/courses/{cid}/attempts", json=body, headers={"Idempotency-Key": "one"}).json()[
            "attempt_id"
        ]
        == result.json()["attempt_id"]
    )
    assert c.post("/api/v1/rewards/consume-events", json={"course_id": cid}).json()["awarded"] == []
    other = c.post("/api/v1/auth/register", json={"username": "other", "password": "password"}).json()[
        "access_token"
    ]
    assert (
        c.get(
            f"/api/v1/courses/{cid}/questions/{q['id']}", headers={"Authorization": "Bearer " + other}
        ).status_code
        == 403
    )
    assert c.post(f"/api/v1/courses/{cid}/archive").status_code == 200
    assert c.get(f"/api/v1/courses/{cid}/questions/{q['id']}").status_code == 403


def test_wrong_or_unrelated_answer_cannot_complete_task(integrated):
    c, cid, q, learning = integrated
    today = datetime.now(timezone(timedelta(hours=8))).date().isoformat()
    task = c.post(
        f"/api/v1/courses/{cid}/planner/tasks",
        json={"title": "另一道题", "type": "practice", "target_id": "other-question", "planned_date": today},
    ).json()
    session = c.post(f"/api/v1/courses/{cid}/questions/{q['id']}/sessions").json()
    result = c.post(
        f"/api/v1/courses/{cid}/attempts",
        headers={"Idempotency-Key": "wrong"},
        json={
            "question_id": q["id"],
            "answer": "0",
            "practice_session_id": session["id"],
            "source_task_id": task["task_id"],
        },
    )
    assert result.status_code == 201 and result.json()["score"] == 0
    assert c.post("/api/v1/rewards/consume-events", json={"course_id": cid}).status_code == 200
    assert c.get("/api/v1/rewards/points").json()["balance"] == 0
    assert c.get(f"/api/v1/planner/tasks/{task['task_id']}").json()["status"] == "pending"


def test_deadline_replan_preserves_completed_and_fixed(integrated):
    c, cid, _, _ = integrated
    today = datetime.now(timezone(timedelta(hours=8))).date()

    def add(title):
        result = c.post(
            f"/api/v1/courses/{cid}/planner/tasks",
            json={
                "type": "lesson",
                "target_id": title,
                "title": title,
                "planned_date": str(today),
                "estimated_minutes": 30,
            },
        )
        assert result.status_code == 200
        return result.json()["task_id"]

    completed, fixed, pending = add("已完成"), add("固定"), add("待安排")
    assert (
        c.post(f"/api/v1/planner/tasks/{completed}/complete", json={"completion": "full"}).status_code == 200
    )
    assert (
        c.post(
            f"/api/v1/planner/tasks/{fixed}/pin", json={"date": str(today + timedelta(days=3))}
        ).status_code
        == 200
    )
    changed = c.patch(
        f"/api/v1/courses/{cid}",
        json={
            "ddl": str(today + timedelta(days=1)),
            "available_slots": [{"weekday": today.isoweekday(), "start": "08:00", "end": "08:10"}],
        },
    )
    assert changed.status_code == 200, changed.text
    result = changed.json()["replan"]
    assert result["warnings"][0]["task_id"] == fixed
    assert result["unscheduled"][0]["task_id"] == pending
    assert c.get(f"/api/v1/planner/tasks/{completed}").json()["status"] == "done"
    assert c.get(f"/api/v1/planner/tasks/{fixed}").json()["planned_date"] == str(today + timedelta(days=3))
