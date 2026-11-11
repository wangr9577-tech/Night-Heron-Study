"""Black-box checks for reward isolation and simultaneous user actions."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from backend.app import core, extra, main


@pytest.fixture
def users(tmp_path, monkeypatch):
    monkeypatch.setattr(core, "DB_PATH", tmp_path / "reward-boundaries.sqlite")
    core.init_core()
    extra.init_extra()
    with TestClient(main.app) as client:
        headers = []
        ids = []
        for name in ("reward_alice", "reward_bob"):
            registration = client.post(
                "/api/v1/auth/register", json={"username": name, "password": "password123"}
            )
            assert registration.status_code == 200
            body = registration.json()
            headers.append({"Authorization": "Bearer " + body["access_token"]})
            ids.append(body["user"]["user_id"])
        yield client, headers, ids


def grant(uid, amount):
    # Set up earned points directly; all actions under test use the HTTP interface.
    with core.db() as connection:
        extra.transaction(connection, uid, "earn", amount, "test", "test", "grant")


def test_concurrent_purchases_cannot_overdraw(users):
    client, (alice, _), (alice_id, _) = users
    grant(alice_id, 10)

    def buy(n):
        return client.post(
            "/api/v1/rewards/exchange",
            headers={**alice, "Idempotency-Key": f"separate-purchase-{n}"},
            json={"item_id": "itm_apple", "qty": 1},
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(buy, range(2)))
    assert sorted(response.status_code for response in results) == [200, 422]
    assert client.get("/api/v1/rewards/points", headers=alice).json()["balance"] == 0
    assert client.get("/api/v1/rewards/bag", headers=alice).json()["items"][0]["qty"] == 1


def test_concurrent_feed_uses_food_only_once(users):
    client, (alice, _), (alice_id, _) = users
    grant(alice_id, 10)
    pet = client.post("/api/v1/companion/pets", headers=alice, json={}).json()
    assert (
        client.post("/api/v1/rewards/exchange", headers=alice, json={"item_id": "itm_apple"}).status_code
        == 200
    )

    def feed(n):
        return client.post(
            "/api/v1/rewards/feed",
            headers={**alice, "Idempotency-Key": f"separate-feed-{n}"},
            json={"pet_id": pet["pet_id"], "item_id": "itm_apple"},
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(feed, range(2)))
    assert sorted(response.status_code for response in results) == [200, 422]
    assert client.get(f"/api/v1/companion/pets/{pet['pet_id']}", headers=alice).json()["growth"]["exp"] == 5
    assert client.get("/api/v1/rewards/bag", headers=alice).json()["items"] == []
    assert (
        len(
            client.get(f"/api/v1/companion/pets/{pet['pet_id']}/growth-events", headers=alice).json()["items"]
        )
        == 1
    )


def test_other_users_pet_cannot_consume_my_food(users):
    client, (alice, bob), (alice_id, _) = users
    grant(alice_id, 10)
    pet = client.post("/api/v1/companion/pets", headers=bob, json={}).json()
    assert (
        client.post("/api/v1/rewards/exchange", headers=alice, json={"item_id": "itm_apple"}).status_code
        == 200
    )
    response = client.post(
        "/api/v1/rewards/feed",
        headers={**alice, "Idempotency-Key": "foreign-pet"},
        json={"pet_id": pet["pet_id"], "item_id": "itm_apple"},
    )
    assert response.status_code == 404
    assert client.get("/api/v1/rewards/bag", headers=alice).json()["items"][0]["qty"] == 1
    assert client.get(f"/api/v1/companion/pets/{pet['pet_id']}", headers=bob).json()["growth"]["exp"] == 0


def test_concurrent_play_and_foreign_access(users):
    client, (alice, bob), _ = users
    pet = client.post("/api/v1/companion/pets", headers=alice, json={}).json()
    url = f"/api/v1/companion/pets/{pet['pet_id']}"
    assert client.post(url + "/interact", headers=bob).status_code == 404
    assert client.get(url + "/growth-summary", headers=bob).status_code == 404

    with ThreadPoolExecutor(max_workers=5) as pool:
        results = list(pool.map(lambda _: client.post(url + "/interact", headers=alice), range(5)))
    assert all(response.status_code == 200 for response in results)
    assert sum(not response.json()["already_done"] for response in results) == 1
    assert len({response.json()["growth_event"]["event_id"] for response in results}) == 1
    summary = client.get(url + "/growth-summary", headers=alice).json()
    assert summary["exp"] == 3
    assert summary["interaction_count"] == 1
    assert summary["interacted_today"] is True


def test_daily_play_resets_at_china_midnight(users, monkeypatch):
    client, (alice, _), _ = users
    pet = client.post("/api/v1/companion/pets", headers=alice, json={}).json()
    url = f"/api/v1/companion/pets/{pet['pet_id']}"

    class Clock(datetime):
        instant = datetime(2026, 11, 8, 15, 59, tzinfo=timezone.utc)

        @classmethod
        def now(cls, tz=None):
            return cls.instant.astimezone(tz) if tz else cls.instant.replace(tzinfo=None)

    monkeypatch.setattr(extra, "datetime", Clock)
    before = client.post(url + "/interact", headers=alice).json()
    assert before["growth_event"]["ref_id"] == "2026-11-08"
    assert client.post(url + "/interact", headers=alice).json()["already_done"] is True
    Clock.instant = datetime(2026, 11, 8, 16, 0, tzinfo=timezone.utc)
    assert client.get(url + "/growth-summary", headers=alice).json()["interacted_today"] is False
    after = client.post(url + "/interact", headers=alice).json()
    assert after["already_done"] is False
    assert after["growth_event"]["ref_id"] == "2026-11-09"
    summary = client.get(url + "/growth-summary", headers=alice).json()
    assert summary["exp"] == 6
    assert summary["interaction_count"] == 2
