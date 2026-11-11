"""Account-scoped sprite storage and optional server-configured generation adapter."""

import base64
import binascii
import hashlib
import io
import json
import os

import httpx
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import Response
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict, Field

from .core import current_user, db, now
from .extra import owned_pet

router = APIRouter(prefix="/api/v1", tags=["Companion sprite"])
MAX_BYTES = 8 * 1024 * 1024
MAX_PROVIDER_BYTES = 12 * 1024 * 1024
SIZES = {(1536, 1872), (1536, 2288)}


class GenerateSprite(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    description: str = Field(min_length=1, max_length=500)


def validate_sprite(content: bytes) -> str:
    if not content or len(content) > MAX_BYTES:
        raise HTTPException(413, "图集文件必须大于 0 且不超过 8 MiB")
    try:
        with Image.open(io.BytesIO(content)) as image:
            if image.format not in {"PNG", "WEBP"}:
                raise HTTPException(415, "图集仅支持 PNG 或 WebP")
            if image.size not in SIZES:
                raise HTTPException(422, "图集尺寸须为 1536×1872 或 1536×2288")
            if getattr(image, "n_frames", 1) != 1:
                raise HTTPException(422, "请上传静态图集，不能使用动画图片")
            mime = "image/png" if image.format == "PNG" else "image/webp"
            image.load()
    except HTTPException:
        raise
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError) as exc:
        raise HTTPException(422, "图集无法解码，请检查文件") from exc
    return mime


_UNCHECKED = object()


def sprite_revision(connection, pet_id):
    row = connection.execute("SELECT revision FROM pet_sprite_revisions WHERE pet_id=?", (pet_id,)).fetchone()
    return row["revision"] if row else 0


def bump_sprite_revision(connection, pet_id):
    connection.execute(
        "INSERT INTO pet_sprite_revisions VALUES (?,1) ON CONFLICT(pet_id) DO UPDATE SET revision=revision+1",
        (pet_id,),
    )


def store_sprite(pet_id: str, user_id: str, content: bytes, expected_revision=_UNCHECKED):
    mime = validate_sprite(content)
    digest, stamp = hashlib.sha256(content).hexdigest(), now()
    with db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        owned_pet(connection, user_id, pet_id)
        if expected_revision is not _UNCHECKED and sprite_revision(connection, pet_id) != expected_revision:
            raise HTTPException(409, "生成期间图集已改变，请重新生成")
        connection.execute(
            """INSERT INTO pet_sprites (pet_id,user_id,mime,content,sha256,updated_at)
            VALUES (?,?,?,?,?,?) ON CONFLICT(pet_id) DO UPDATE SET
            user_id=excluded.user_id,mime=excluded.mime,content=excluded.content,
            sha256=excluded.sha256,updated_at=excluded.updated_at""",
            (pet_id, user_id, mime, content, digest, stamp),
        )
        bump_sprite_revision(connection, pet_id)
    return {"pet_id": pet_id, "mime": mime, "sha256": digest, "updated_at": stamp}


@router.get("/companion/sprite-capabilities")
def capabilities(uid: str = Depends(current_user)):
    return {
        "generation_configured": bool(os.getenv("ZHI_PET_SPRITE_URL", "").strip()),
        "format": "codex-sprite-sheet-v1",
        "columns": 8,
        "tile_width": 192,
        "tile_height": 208,
        "accepted_sizes": [[1536, 1872], [1536, 2288]],
        "max_bytes": MAX_BYTES,
    }


@router.get("/companion/pets/{pet_id}/sprite")
def get_sprite(pet_id: str, uid: str = Depends(current_user)):
    with db() as connection:
        owned_pet(connection, uid, pet_id)
        row = connection.execute(
            "SELECT mime,content,sha256 FROM pet_sprites WHERE pet_id=? AND user_id=?", (pet_id, uid)
        ).fetchone()
        if row is None:
            raise HTTPException(404, "伙伴还没有自定义图集")
        return Response(
            content=row["content"],
            media_type=row["mime"],
            headers={"ETag": '"' + row["sha256"] + '"', "Cache-Control": "private, no-store"},
        )


@router.put("/companion/pets/{pet_id}/sprite")
async def upload_sprite(pet_id: str, file: UploadFile = File(...), uid: str = Depends(current_user)):
    # Check ownership before reading or decoding potentially large data.
    with db() as connection:
        owned_pet(connection, uid, pet_id)
    try:
        content = await file.read(MAX_BYTES + 1)
    finally:
        await file.close()
    return store_sprite(pet_id, uid, content)


@router.delete("/companion/pets/{pet_id}/sprite")
def delete_sprite(pet_id: str, uid: str = Depends(current_user)):
    with db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        owned_pet(connection, uid, pet_id)
        removed = connection.execute(
            "DELETE FROM pet_sprites WHERE pet_id=? AND user_id=?", (pet_id, uid)
        ).rowcount
        bump_sprite_revision(connection, pet_id)
    return {"ok": True, "removed": bool(removed)}


def generator_client():
    """Factory separated to allow network-free MockTransport contract tests."""
    return httpx.Client(timeout=httpx.Timeout(120, connect=10), follow_redirects=False)


@router.post("/companion/pets/{pet_id}/sprite/generate")
def generate_sprite(pet_id: str, body: GenerateSprite, uid: str = Depends(current_user)):
    with db() as connection:
        owned_pet(connection, uid, pet_id)
        expected_revision = sprite_revision(connection, pet_id)
    url = os.getenv("ZHI_PET_SPRITE_URL", "").strip()
    if not url:
        raise HTTPException(503, "服务器尚未配置宠物图集生成服务")
    headers = {"Accept": "application/json"}
    key = os.getenv("ZHI_PET_SPRITE_API_KEY", "")
    if key:
        headers["Authorization"] = "Bearer " + key
    payload = {
        "description": body.description,
        "format": "codex-sprite-sheet-v1",
        "columns": 8,
        "rows": 9,
        "tile_width": 192,
        "tile_height": 208,
    }
    try:
        with generator_client() as client, client.stream("POST", url, json=payload, headers=headers) as r:
            r.raise_for_status()
            chunks, length = [], 0
            for chunk in r.iter_bytes():
                length += len(chunk)
                if length > MAX_PROVIDER_BYTES:
                    raise HTTPException(502, "生成服务返回内容过大")
                chunks.append(chunk)
            data = json.loads(b"".join(chunks))
        encoded = data["image_base64"]
        if not isinstance(encoded, str) or len(encoded) > (MAX_BYTES + 2) // 3 * 4:
            raise ValueError("invalid encoded size")
        content = base64.b64decode(encoded, validate=True)
    except HTTPException:
        raise
    except (httpx.HTTPError, ValueError, KeyError, TypeError, binascii.Error) as exc:
        # Do not return provider responses or exception strings: they may contain secrets.
        raise HTTPException(502, "宠物图集生成服务不可用或返回格式无效") from exc
    try:
        return {**store_sprite(pet_id, uid, content, expected_revision=expected_revision), "generated": True}
    except HTTPException as exc:
        if exc.status_code in (404, 409):
            raise
        raise HTTPException(502, "生成服务返回的图集不符合尺寸或格式要求") from exc
