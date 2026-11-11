"""Exercise sprite generation over real loopback HTTP with isolated synthetic data.

This does not invoke a real AI service or touch the default application database.
"""

import base64
import hashlib
import io
import json
import logging
import os
import socket
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx
import uvicorn
from PIL import Image


def main():
    root = Path(__file__).resolve().parents[1]
    output = root / "output" / "pet-sprite-http"
    output.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=output))
    os.environ["ZHI_DB_PATH"] = str(run / "isolated.sqlite3")
    os.environ["ZHUOZHI_DATA_DIR"] = str(run / "learning")
    os.environ["ZHI_PET_SPRITE_API_KEY"] = "isolated-test-key"

    image_file = io.BytesIO()
    Image.new("RGBA", (1536, 1872), (18, 135, 93, 255)).save(image_file, "PNG")
    image = image_file.getvalue()
    state = {"mode": "valid", "calls": 0}

    class MockGenerator(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_POST(self):
            state["calls"] += 1
            size = int(self.headers.get("Content-Length", "0"))
            try:
                payload = json.loads(self.rfile.read(size))
                valid = (
                    self.headers.get("Authorization") == "Bearer isolated-test-key"
                    and payload["format"] == "codex-sprite-sheet-v1"
                    and payload["columns"] == 8
                    and payload["rows"] == 9
                )
                if not valid:
                    self.send_error(400)
                    return
                if state["mode"] == "error":
                    self.send_error(503)
                    return
                content = image if state["mode"] == "valid" else b"invalid image"
                data = json.dumps({"image_base64": base64.b64encode(content).decode("ascii")}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (ValueError, KeyError, TypeError):
                self.send_error(400)

    generator = ThreadingHTTPServer(("127.0.0.1", 0), MockGenerator)
    generator_thread = threading.Thread(target=generator.serve_forever, daemon=True)
    generator_thread.start()
    os.environ["ZHI_PET_SPRITE_URL"] = f"http://127.0.0.1:{generator.server_port}/generate"

    # Import only after setting isolated paths and trusted mock URL.
    from backend.app.main import app

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    backend_port = listener.getsockname()[1]
    logging.basicConfig(filename=run / "backend.log", level=logging.WARNING, encoding="utf-8")
    server = uvicorn.Server(uvicorn.Config(app, log_level="warning", log_config=None))
    backend_thread = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
    backend_thread.start()
    statuses = {}
    try:
        with httpx.Client(base_url=f"http://127.0.0.1:{backend_port}", timeout=30, trust_env=False) as c:
            for _ in range(100):
                try:
                    if c.get("/healthz").status_code == 200:
                        break
                except httpx.HTTPError:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("isolated backend did not become healthy")

            def account(name):
                response = c.post("/api/v1/auth/register", json={"username": name, "password": "isolate123"})
                assert response.status_code == 200
                return {"Authorization": "Bearer " + response.json()["access_token"]}

            first, second = account("sprite-alice"), account("sprite-bob")
            created = c.post("/api/v1/companion/pets", headers=first, json={})
            assert created.status_code == 200
            path = "/api/v1/companion/pets/" + created.json()["pet_id"] + "/sprite"
            capability = c.get("/api/v1/companion/sprite-capabilities", headers=first)
            assert capability.status_code == 200 and capability.json()["generation_configured"] is True
            generated = c.post(path + "/generate", headers=first, json={"description": "synthetic test bird"})
            statuses["generate"] = generated.status_code
            assert generated.status_code == 200 and generated.json()["generated"] is True
            fetched = c.get(path, headers=first)
            statuses["read"] = fetched.status_code
            assert fetched.content == image and fetched.headers["content-type"] == "image/png"
            denied = c.get(path, headers=second)
            statuses["other_account_read"] = denied.status_code
            assert denied.status_code == 404
            denied_generate = c.post(path + "/generate", headers=second, json={"description": "denied"})
            statuses["other_account_generate"] = denied_generate.status_code
            assert denied_generate.status_code == 404 and state["calls"] == 1
            for mode in ("invalid", "error"):
                state["mode"] = mode
                failed = c.post(path + "/generate", headers=first, json={"description": "bad fixture"})
                statuses["provider_" + mode] = failed.status_code
                assert failed.status_code == 502
                assert c.get(path, headers=first).content == image
            deleted = c.delete(path, headers=first)
            assert deleted.status_code == 200 and deleted.json()["removed"] is True
            assert c.get(path, headers=first).status_code == 404
            statuses["delete"] = deleted.status_code
        result = {
            "all_passed": True,
            "real_http": True,
            "generation_provider": "synthetic local mock; not a real AI service",
            "backend_port": backend_port,
            "mock_provider_port": generator.server_port,
            "image_dimensions": [1536, 1872],
            "image_sha256": hashlib.sha256(image).hexdigest(),
            "http_statuses": statuses,
        }
        (run / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({"run": str(run), **result}, ensure_ascii=False))
    finally:
        server.should_exit = True
        backend_thread.join(timeout=15)
        generator.shutdown()
        generator.server_close()
        generator_thread.join(timeout=5)
        listener.close()
        if backend_thread.is_alive():
            raise RuntimeError("isolated backend did not stop")


if __name__ == "__main__":
    main()
