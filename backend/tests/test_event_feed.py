import httpx
import pytest
from fastapi import HTTPException

from backend.app import core, event_feed, extra, main


@pytest.fixture
def account(tmp_path, monkeypatch):
    monkeypatch.setenv("ZHI_B_BASE_URL", "https://example.test/api/v1")
    monkeypatch.setattr(core, "DB_PATH", tmp_path / "events.db")
    core.init_core()
    extra.init_extra()
    uid = main.register(main.Credentials(username="learner", password="password"))["user"]["user_id"]
    cid = main.create_course(main.CourseInput(title="课"), uid)["course_id"]
    return uid, cid


def test_page_checkpoint_atomic_and_duplicate(monkeypatch, account):
    uid, cid = account
    event = {
        "event_id": "evt_1",
        "user_id": uid,
        "course_id": cid,
        "event_type": "practice_graded",
        "result": {"passed": True},
    }
    seen = []

    def read(token, course, cursor):
        seen.append((token, course, cursor))
        return [event], "page2" if cursor is None else None

    monkeypatch.setattr(event_feed, "read_events", read)
    request = extra.ConsumeRequest(course_id=cid)
    assert extra.consume_events(request, uid, "Bearer delegated")["awarded"][0]["points"] == 5
    assert extra.consume_events(request, uid, "Bearer delegated")["consumed"] == 0
    assert extra.consume_events(request, uid, "Bearer delegated")["consumed"] == 0
    assert [x[2] for x in seen] == [None, "page2", "page2"]
    with core.db() as c:
        assert c.execute("SELECT balance FROM balances WHERE user_id=?", (uid,)).fetchone()[0] == 5
        assert c.execute("SELECT cursor FROM event_cursors WHERE user_id=?", (uid,)).fetchone()[0] == "page2"


def test_reject_invalid_batch_without_advancing(monkeypatch, account):
    uid, cid = account
    good = {
        "event_id": "evt_good",
        "user_id": uid,
        "course_id": cid,
        "event_type": "practice_graded",
        "result": {"passed": True},
    }
    bad = {
        "event_id": "evt_bad",
        "user_id": "someone_else",
        "course_id": cid,
        "event_type": "practice_graded",
        "result": {"passed": True},
    }
    monkeypatch.setattr(event_feed, "read_events", lambda *args: ([good, bad], "next"))
    with pytest.raises(HTTPException) as exc:
        extra.consume_events(extra.ConsumeRequest(course_id=cid), uid, "Bearer delegated")
    assert exc.value.status_code == 502
    with core.db() as c:
        assert c.execute("SELECT COUNT(*) FROM transactions").fetchone()[0] == 0
        assert c.execute("SELECT COUNT(*) FROM event_cursors").fetchone()[0] == 0


def test_adapter_auth_and_demo_rejection(monkeypatch):
    monkeypatch.setenv("ZHI_B_BASE_URL", "https://example.test/api/v1")
    seen = []

    def respond(request):
        seen.append(request)
        return httpx.Response(200, json={"events": [], "next_cursor": None, "is_demo": True})

    real_client = httpx.Client
    monkeypatch.setattr(
        event_feed.httpx,
        "Client",
        lambda **kwargs: real_client(transport=httpx.MockTransport(respond), **kwargs),
    )
    with pytest.raises(event_feed.FeedError):
        event_feed.read_events("token", "crs_1", None)
    assert seen[0].headers["authorization"] == "Bearer token"
    assert seen[0].url.path == "/api/v1/learning-events"
    monkeypatch.setenv("ZHI_B_BASE_URL", "http://remote.example/api/v1")
    with pytest.raises(event_feed.FeedError):
        event_feed.read_events("token", None, None)
