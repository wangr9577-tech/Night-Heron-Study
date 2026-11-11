"""Live HTTP check, requires scripts/start.ps1 (or Uvicorn) already running."""

import argparse
import json
import time
from pathlib import Path
from uuid import uuid4

import httpx


def main(base_url):
    rows = []
    prefix = "/api/v1/courses/course-demo"
    with httpx.Client(
        base_url=base_url, timeout=15, headers={"Authorization": "Bearer demo-token"}
    ) as client:

        def call(method, route, expected=200, **kwargs):
            response = client.request(
                method, route if route.startswith("/api/") or route == "/health" else prefix + route, **kwargs
            )
            assert response.status_code == expected, (route, response.status_code, response.text)
            data = response.json()
            rows.append(dict(method=method, path=route, status_code=response.status_code, response=data))
            return data

        def finish(job):
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                current = call("GET", "/jobs/" + job["job_id"])
                if current["status"] == "succeeded":
                    return current["result_ref"]
                assert current["status"] != "failed", current
                time.sleep(0.25)
            raise AssertionError("Background job timeout")

        health = call("GET", "/health")
        assert health["mode"] == "demo"
        call("GET", "/materials", expected=401, headers={"Authorization": ""})
        call("GET", "/materials", expected=403, headers={"Authorization": "Bearer other-token"})
        data = Path("examples/inputs/basic.md").read_bytes()
        upload = call("POST", "/materials", expected=202, files={"file": ("smoke.md", data)})
        finish(upload["job"])
        graph = call("POST", "/knowledge/extract", json={"material_ids": [upload["material_id"]]})
        con = next(n for n in graph["nodes"] if n["title"] == "一元一次方程")
        call("POST", "/tutoring/ask", json={"question": "一元一次方程"})
        lesson = finish(call("POST", "/lessons", expected=202, json={"concept_ids": [con["id"]]}))
        call("GET", "/lessons/" + lesson["id"])
        blueprint = call(
            "POST",
            "/exam-blueprints",
            expected=201,
            json={"slots": [{"concept_id": con["id"], "count": 1, "kind": "numeric"}]},
        )
        eid = finish(call("POST", "/exams", expected=202, json={"blueprint_id": blueprint["id"]}))["id"]
        exam = call("GET", "/exams/" + eid)
        qid = exam["items"][0]["question_id"]
        session = call("POST", f"/questions/{qid}/sessions", expected=201)
        body = dict(
            question_id=qid,
            answer="-999",
            practice_session_id=session["id"],
            exam_id=eid,
            source_task_id="A-http-smoke-task",
        )
        headers = {"Idempotency-Key": "http-smoke-" + uuid4().hex}
        first = call("POST", "/attempts", expected=201, json=body, headers=headers)
        retry = call("POST", "/attempts", expected=201, json=body, headers=headers)
        assert first["attempt_id"] == retry["attempt_id"] and first["score"] == 0
        mistake = call("GET", "/mistakes")["items"][-1]
        finish(
            call("POST", f"/mistakes/{mistake['id']}/variants", expected=202, json={"count": 1, "seed": 9})
        )
        call("GET", "/learning-snapshot")
        events = call("GET", "/api/v1/learning-events?limit=200")
        assert len({e["event_id"] for e in events["items"]}) == len(events["items"])
        exhausted = call("GET", "/api/v1/learning-events?cursor=" + events["next_cursor"])
        assert exhausted["items"] == []
    output = Path("output/verification/http-smoke.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(
            dict(base_url=base_url, checks=len(rows), all_passed=True, calls=rows),
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"Live HTTP: {len(rows)} checks passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    main(parser.parse_args().base_url)
