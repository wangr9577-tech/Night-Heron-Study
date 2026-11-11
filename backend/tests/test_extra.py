import pytest
from fastapi import HTTPException

from backend.app import core, extra, main


@pytest.fixture
def setup(tmp_path, monkeypatch):
    monkeypatch.setattr(core, "DB_PATH", tmp_path / "test.db")
    core.init_core()
    extra.init_extra()


def register(name):
    return main.register(main.Credentials(username=name, password="password123"))["user"]["user_id"]


def test_pet_isolation_and_memory(setup):
    a = register("alice")
    b = register("bob")
    pet = extra.create_pet(extra.PetInput(name="啄啄"), a)
    pid = pet["pet_id"]
    with pytest.raises(HTTPException) as e:
        extra.get_pet(pid, b)
    assert e.value.status_code == 404
    mem = extra.add_memory(pid, extra.Content(content="喜欢数学"), a)
    assert (
        extra.edit_memory(pid, mem["memory_id"], extra.Content(content="喜欢物理"), a)["content"]
        == "喜欢物理"
    )
    assert extra.delete_memory(pid, mem["memory_id"], a)["ok"]
    assert extra.chat(pid, extra.Content(content="你好"), a)["is_demo"]


def test_event_idempotency_and_exchange(setup):
    uid = register("amy")
    course = main.create_course(main.CourseInput(title="数学"), uid)
    cid = course["course_id"]
    task = main.create_task(
        cid, main.TaskInput(type="practice", target_id="q1", title="练习", planned_date="2026-11-06"), uid
    )
    event = {
        "event_id": "evt_test",
        "user_id": uid,
        "course_id": cid,
        "source_task_id": task["task_id"],
        "event_type": "task_criteria_met",
        "result": {},
    }
    with core.db() as c:
        assert extra.consume_verified_events(c, uid, [event])["consumed"] == 1
    with core.db() as c:
        assert extra.consume_verified_events(c, uid, [event])["consumed"] == 0
    assert extra.points(uid)["balance"] == 20
    assert main.task_detail(task["task_id"], uid)["status"] == "done"
    assert extra.exchange(extra.Exchange(item_id="itm_apple"), uid)["bag_item"]["qty"] == 1
    pet = extra.create_pet(extra.PetInput(), uid)
    assert extra.feed(extra.Feed(pet_id=pet["pet_id"], item_id="itm_apple"), uid)["bag_item"]["qty"] == 0
    with pytest.raises(HTTPException):
        extra.feed(extra.Feed(pet_id=pet["pet_id"], item_id="itm_apple"), uid)
    assert extra.consume_events(extra.ConsumeRequest(), uid, "Bearer test")["consumed"] == 0


def test_speech_and_notifications(setup):
    uid = register("sue")
    t = extra.TTSRequest(text="hello", cache_key="segment1")
    one = extra.tts(t, uid)
    two = extra.tts(t, uid)
    assert (
        one["is_demo"]
        and two["is_demo"]
        and two["cache_hit"]
        and extra.audio(one["audio_id"], uid).body[:4] == b"RIFF"
    )
    scene = extra.scenes(uid)["items"][0]
    session = extra.create_session(extra.SessionInput(scene_id=scene["scene_id"]), uid)["session"]
    sid = session["session_id"]
    turn = extra.oral_turn(sid, extra.TurnInput(transcript="Hello"), uid)
    assert turn["is_demo"] and turn["turn"]["user_text"] == "Hello"
    summary = extra.finish(sid, uid)
    assert summary["is_demo"] and summary["summary"]["turns"] == 1
    assert (
        extra.update_settings(extra.NotificationPatch(in_app_enabled=False), uid)["in_app_enabled"] is False
    )
    assert (
        extra.generate_notifications(
            extra.GenerateRequest(date=extra.datetime.now(extra.LOCAL_TZ).date().isoformat()), uid
        )["items"]
        == []
    )


def test_http_extra_routes(setup):
    from fastapi.testclient import TestClient

    with TestClient(main.app) as client:
        login = client.post("/api/v1/auth/register", json={"username": "webuser", "password": "password123"})
        assert login.status_code == 200
        h = {"Authorization": "Bearer " + login.json()["access_token"]}
        pet = client.post("/api/v1/companion/pets", headers=h, json={})
        assert pet.status_code == 200 and pet.json()["name"] == "小啄"
        tts = client.post("/api/v1/speech/tts", headers=h, json={"text": "hello"})
        assert tts.status_code == 200 and tts.json()["is_demo"]
        assert client.get(tts.json()["url"], headers=h).content[:4] == b"RIFF"
        assert client.post("/api/v1/rewards/consume-events", headers=h, json={}).status_code == 200


def test_notifications_schedule_dedup_and_dnd(setup):
    uid = register("notify")
    local = extra.datetime(2026, 11, 6, 12, 0, tzinfo=extra.LOCAL_TZ)
    course = main.create_course(main.CourseInput(title="数学", ddl="2026-11-06"), uid)
    main.create_task(
        course["course_id"],
        main.TaskInput(type="lesson", target_id="a", title="学习", planned_date="2026-11-06"),
        uid,
    )
    notices = extra.generate_due_notifications(uid, local)
    assert {n["type"] for n in notices} == {"ddl", "task_due"}
    assert extra.generate_due_notifications(uid, local) == []
    extra.update_settings(extra.NotificationPatch(dnd={"start": "11:00", "end": "13:00"}), uid)
    assert extra.generate_due_notifications(uid, local) == []
