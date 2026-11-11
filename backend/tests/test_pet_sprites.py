import base64
import io
import json

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from backend.app import core, extra, main, pet_sprites


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(core, "DB_PATH", tmp_path / "test.sqlite3")
    monkeypatch.delenv("ZHI_PET_SPRITE_URL", raising=False)
    monkeypatch.delenv("ZHI_PET_SPRITE_API_KEY", raising=False)
    core.init_core()
    extra.init_extra()
    with TestClient(main.app) as client:
        yield client


def image_bytes(size=(1536, 1872), fmt="PNG", animated=False):
    image = Image.new("RGBA", size, (255, 0, 0, 128))
    buf = io.BytesIO()
    second = image.copy()
    second.putpixel((0, 0), (0, 0, 0, 255))
    options = {"save_all": True, "append_images": [second], "duration": 50} if animated else {}
    image.save(buf, format=fmt, **options)
    return buf.getvalue()


def account(client, username):
    response = client.post("/api/v1/auth/register", json={"username": username, "password": "password123"})
    assert response.status_code == 200
    return {"Authorization": "Bearer " + response.json()["access_token"]}


def test_sprite_upload_download_delete_and_account_isolation(client):
    alice, bob = account(client, "alice-sprites"), account(client, "bob-sprites")
    pet = client.post("/api/v1/companion/pets", headers=alice, json={}).json()["pet_id"]
    path = f"/api/v1/companion/pets/{pet}/sprite"
    png = image_bytes()
    assert client.get(path, headers=alice).status_code == 404
    response = client.put(path, headers=alice, files={"file": ("pet.png", png, "image/png")})
    assert response.status_code == 200
    download = client.get(path, headers=alice)
    assert download.content == png and download.headers["content-type"] == "image/png"
    assert download.headers["cache-control"] == "private, no-store"
    assert client.get(path, headers=bob).status_code == 404
    assert client.put(path, headers=bob, files={"file": ("pet.png", png, "image/png")}).status_code == 404
    assert client.delete(path, headers=bob).status_code == 404
    for bad in (b"not an image", image_bytes(size=(192, 208)), image_bytes(animated=True)):
        assert client.put(path, headers=alice, files={"file": ("x.png", bad, "image/png")}).status_code == 422
        assert client.get(path, headers=alice).content == png
    assert (
        client.put(
            path, headers=alice, files={"file": ("x.png", b"x" * (pet_sprites.MAX_BYTES + 1))}
        ).status_code
        == 413
    )
    webp = image_bytes(size=(1536, 2288), fmt="WEBP")
    assert (
        client.put(path, headers=alice, files={"file": ("sprite.webp", webp, "image/webp")}).status_code
        == 200
    )
    assert client.get(path, headers=alice).headers["content-type"] == "image/webp"
    assert client.delete(path, headers=alice).json()["removed"] is True
    assert client.delete(path, headers=alice).json()["removed"] is False
    assert client.get(path, headers=alice).status_code == 404


def test_generation_requires_config_and_validates_provider_result(client, monkeypatch):
    auth = account(client, "generator")
    other = account(client, "other-generator")
    pet = client.post("/api/v1/companion/pets", headers=auth, json={}).json()["pet_id"]
    path = f"/api/v1/companion/pets/{pet}/sprite"
    assert (
        client.get("/api/v1/companion/sprite-capabilities", headers=auth).json()["generation_configured"]
        is False
    )
    assert (
        client.post(path + "/generate", headers=auth, json={"description": "small bird"}).status_code == 503
    )
    assert (
        client.post(
            path + "/generate", headers=auth, json={"description": "bird", "url": "http://evil"}
        ).status_code
        == 400
    )

    monkeypatch.setenv("ZHI_PET_SPRITE_URL", "https://example.test/generate")
    monkeypatch.setenv("ZHI_PET_SPRITE_API_KEY", "secret-not-for-client")
    png = image_bytes()
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, json={"image_base64": base64.b64encode(png).decode()})

    monkeypatch.setattr(
        pet_sprites, "generator_client", lambda: httpx.Client(transport=httpx.MockTransport(handler))
    )
    assert client.post(path + "/generate", headers=other, json={"description": "bird"}).status_code == 404
    assert not requests
    result = client.post(path + "/generate", headers=auth, json={"description": "small bird"})
    assert result.status_code == 200 and result.json()["generated"] is True
    assert "secret-not-for-client" not in result.text
    assert requests[0].headers["authorization"] == "Bearer secret-not-for-client"
    assert json.loads(requests[0].content)["columns"] == 8
    assert client.get(path, headers=auth).content == png

    replacement = image_bytes(size=(1536, 2288), fmt="WEBP")

    def changed_while_generating(_):
        owner = core.current_user(auth["Authorization"])
        pet_sprites.store_sprite(pet, owner, replacement)
        return httpx.Response(200, json={"image_base64": base64.b64encode(png).decode()})

    monkeypatch.setattr(
        pet_sprites,
        "generator_client",
        lambda: httpx.Client(transport=httpx.MockTransport(changed_while_generating)),
    )
    assert client.post(path + "/generate", headers=auth, json={"description": "bird"}).status_code == 409
    assert client.get(path, headers=auth).content == replacement

    def invalid(_):
        return httpx.Response(200, json={"image_base64": base64.b64encode(b"bad").decode()})

    monkeypatch.setattr(
        pet_sprites, "generator_client", lambda: httpx.Client(transport=httpx.MockTransport(invalid))
    )
    result = client.post(path + "/generate", headers=auth, json={"description": "bad"})
    assert result.status_code == 502
    assert client.get(path, headers=auth).content == replacement

    def failed(_):
        return httpx.Response(500, text="secret-not-for-client")

    monkeypatch.setattr(
        pet_sprites, "generator_client", lambda: httpx.Client(transport=httpx.MockTransport(failed))
    )
    result = client.post(path + "/generate", headers=auth, json={"description": "bad"})
    assert result.status_code == 502 and "secret-not-for-client" not in result.text
    assert client.get(path, headers=auth).content == replacement

    # A delete is an explicit choice even if the slot later returns to empty.
    assert client.delete(path, headers=auth).status_code == 200

    def deleted_while_generating(_):
        owner = core.current_user(auth["Authorization"])
        pet_sprites.delete_sprite(pet, owner)
        return httpx.Response(200, json={"image_base64": base64.b64encode(png).decode()})

    monkeypatch.setattr(
        pet_sprites,
        "generator_client",
        lambda: httpx.Client(transport=httpx.MockTransport(deleted_while_generating)),
    )
    assert client.post(path + "/generate", headers=auth, json={"description": "bird"}).status_code == 409
    assert client.get(path, headers=auth).status_code == 404
