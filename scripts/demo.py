"""Reproduce B1–B8 with real Chinese PDF/image/PPTX/PDF exports; no API key required.

Run: .venv/Scripts/python.exe -m scripts.demo
Every run uses a fresh private DB under tmp. Only documented output/demo artifacts are replaced.
"""

import argparse
import json
import os
import shutil
import subprocess
from html import escape
from pathlib import Path
from uuid import uuid4

import pymupdf
from fastapi.testclient import TestClient
from PIL import Image, ImageDraw, ImageFont

from backend.app import create_app
from backend.engine.config import Settings
from scripts.render_pptx import render


def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def text_pdf(text, target):
    html = (
        "<html><body>"
        + "".join("<p>" + escape(line) + "</p>" for line in text.splitlines() if line.strip())
        + "</body></html>"
    )
    story = pymupdf.Story(html=html, user_css="body{font-family:sans-serif;font-size:12pt;line-height:1.7}")
    writer = pymupdf.DocumentWriter(str(target))
    more = True
    while more:
        device = writer.begin_page(pymupdf.paper_rect("a4"))
        more, _ = story.place(pymupdf.Rect(42, 42, 553, 800))
        story.draw(device)
        writer.end_page()
    writer.close()


def main(output):
    root = Path(__file__).resolve().parents[1]
    output = (root / output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    inputs = output / "inputs"
    inputs.mkdir(exist_ok=True)
    runtime = root / "tmp" / ("demo-" + uuid4().hex)
    text = (root / "examples/inputs/basic.md").read_text(encoding="utf-8")
    text_pdf(text, inputs / "textbook.pdf")
    text_pdf(
        "原卷示例\n1. 一元一次方程（10分）：解方程 2x+3=11。\n2. 算术平均数（10分）：计算 2、4、6 的算术平均数。",
        inputs / "original-exam.pdf",
    )
    image = Image.new("RGB", (1200, 360), "white")
    # A text-only OCR fixture, not a visual illustration.
    fontpath = Path(os.getenv("WINDIR", "C:/Windows")) / "Fonts/msyh.ttc"
    font = ImageFont.truetype(str(fontpath), 40)
    draw = ImageDraw.Draw(image)
    draw.text((45, 40), "一元一次方程", fill="black", font=font)
    draw.text((45, 120), "2x + 3 = 11", fill="black", font=font)
    draw.text((45, 200), "我的作答：x = 5", fill="black", font=font)
    image.save(inputs / "mistake-photo.png")
    scanned = pymupdf.open()
    p = scanned.new_page(width=600, height=180)
    p.insert_image(p.rect, filename=str(inputs / "mistake-photo.png"))
    scanned.save(inputs / "scanned.pdf")
    scanned.close()

    app = create_app(Settings(data_dir=runtime, mode="demo", worker_enabled=False))
    requests, errors = [], []
    base = "/api/v1/courses/course-demo"
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer demo-token"

        def call(method, route, body=None, author=False, expected=None, **kwargs):
            headers = kwargs.pop("headers", {})
            if author:
                headers["Authorization"] = "Bearer author-token"
            r = client.request(
                method.upper(),
                route if route.startswith("/api/") else base + route,
                json=body,
                headers=headers,
                **kwargs,
            )
            record = dict(method=method.upper(), path=route, request=body, status_code=r.status_code)
            try:
                data = r.json()
            except ValueError:
                data = {"binary_bytes": len(r.content)}
            record["response"] = data
            if expected:
                assert r.status_code == expected, record
                errors.append(record)
            else:
                assert r.is_success, record
                requests.append(record)
            return data

        def upload(name):
            return call("post", "/materials", files={"file": (name, (inputs / name).read_bytes())})

        def finish(job):
            for _ in range(30):
                current = call("get", "/jobs/" + job["job_id"])
                if current["status"] == "succeeded":
                    return current["result_ref"]
                assert current["status"] != "failed", current
                app.state.learning_engine.queue.run_one()
            raise AssertionError("job timeout")

        def submit(qid, answer, key, **extra):
            session = call("post", f"/questions/{qid}/sessions")
            body = dict(question_id=qid, answer=answer, practice_session_id=session["id"], **extra)
            return call("post", "/attempts", body, headers={"Idempotency-Key": key})

        material_job = upload("textbook.pdf")
        finish(material_job["job"])
        material = call("get", "/materials/" + material_job["material_id"])
        save_json(output / "B1-material.json", material)
        ocr_job = upload("mistake-photo.png")
        finish(ocr_job["job"])
        save_json(output / "B1-ocr.json", call("get", "/materials/" + ocr_job["material_id"]))
        scan = upload("scanned.pdf")
        finish(scan["job"])
        save_json(output / "B1-scanned-pdf.json", call("get", "/materials/" + scan["material_id"]))
        graph = call("post", "/knowledge/extract", {"material_ids": [material["id"]]})
        one = next(n for n in graph["nodes"] if n["title"] == "一元一次方程")
        mean = next(n for n in graph["nodes"] if n["title"] == "算术平均数")
        call("post", "/knowledge/edges", dict(from_id=one["id"], to_id=mean["id"], type="related"))
        save_json(output / "B2-knowledge.json", call("get", "/knowledge"))
        reply = call("post", "/tutoring/ask", {"question": "一元一次方程怎样求解？"})
        save_json(output / "B3-tutoring.json", reply)
        lesson_job = call(
            "post", "/lessons", {"title": "方程与算术平均数", "concept_ids": [one["id"], mean["id"]]}
        )
        lesson_id = finish(lesson_job)["id"]
        lesson = call("get", "/lessons/" + lesson_id)
        save_json(output / "B4-lesson.json", lesson)
        shutil.copy2(runtime / "files" / lesson["pptx_filename"], output / "B4-lesson.pptx")
        previews = output / "lesson-previews"
        preview_report = render(output / "B4-lesson.pptx", previews, output / "render-report.json")
        assert preview_report["slide_count"] == len(lesson["pages"])
        soffice = os.getenv("ZHUOZHI_SOFFICE")
        local_soffice = root / ".tools/LibreOffice/program/soffice.com"
        if not soffice and local_soffice.is_file():
            soffice = str(local_soffice)
        if soffice:
            subprocess.run(
                [
                    soffice,
                    "-env:UserInstallation=" + (runtime / "legacy-export-profile").as_uri(),
                    "--headless",
                    "--convert-to",
                    "ppt:MS PowerPoint 97",
                    "--outdir",
                    str(inputs),
                    str(output / "B4-lesson.pptx"),
                ],
                check=True,
                capture_output=True,
                timeout=90,
            )
            legacy_job = upload("B4-lesson.ppt")
            finish(legacy_job["job"])
            legacy = call("get", "/materials/" + legacy_job["material_id"])
            assert "不为零" in "".join(p["text"] for p in legacy["pages"])
            save_json(output / "B1-legacy-ppt.json", legacy)
        page = lesson["pages"][0]
        call(
            "put",
            "/lessons/" + lesson_id + "/position",
            dict(
                page_id=page["page_id"],
                segment_id=page["narration_segments"][0]["segment_id"],
                source_task_id="A-task-lesson",
                offset_seconds=8,
            ),
        )
        original = upload("original-exam.pdf")
        finish(original["job"])
        save_json(
            output / "B5-original-analysis.json",
            call("post", "/exams/analyze", {"material_id": original["material_id"]}),
        )
        bp = call(
            "post",
            "/exam-blueprints",
            {
                "title": "方程与统计仿真卷",
                "slots": [
                    dict(concept_id=one["id"], count=2, kind="numeric", points=20),
                    dict(concept_id=mean["id"], count=1, kind="numeric", points=20),
                    dict(concept_id=one["id"], count=2, kind="cloze", points=20),
                ],
            },
        )
        save_json(output / "B5-blueprint.json", bp)
        ejob = call("post", "/exams", {"blueprint_id": bp["id"], "seed": 44})
        eid = finish(ejob)["id"]
        exam = call("get", "/exams/" + eid)
        save_json(output / "B5-exam.json", exam)
        shutil.copy2(runtime / "files" / exam["paper_filename"], output / "B5-paper.pdf")
        shutil.copy2(runtime / "files" / exam["answers_filename"], output / "B5-answers.pdf")
        exam_answers = [
            call("get", "/questions/" + item["question_id"] + "/answer-key", author=True)
            for item in exam["items"]
        ]
        save_json(output / "B5-answer-key.json", {"questions": exam_answers})
        qid = exam["items"][0]["question_id"]
        wrong = submit(qid, "-999", "demo-wrong", exam_id=eid, source_task_id="A-task-exam")
        mistake = call("get", "/mistakes")["items"][0]
        mid = mistake["id"]
        variants = finish(call("post", f"/mistakes/{mid}/variants", {"count": 2, "seed": 8}))["question_ids"]
        vkey = call("get", f"/questions/{variants[0]}/answer-key", author=True)
        correct = submit(vkey["id"], vkey["answer"], "demo-variant", source_task_id="A-task-variant")
        save_json(output / "B6-mistake.json", call("get", "/mistakes/" + mid))
        save_json(output / "B6-steps.json", call("get", f"/mistakes/{mid}/explanation"))
        captured = call(
            "post", "/mistakes/capture", {"material_id": ocr_job["material_id"], "original_answer": "x = 5"}
        )
        call("post", f"/mistakes/{captured['id']}/variants", {"count": 1}, expected=409)
        qdraft = dict(
            kind="numeric",
            prompt="解方程 2x+3=11，求 x。",
            answer="4",
            concept_ids=[one["id"]],
            source_refs=one["source_refs"],
            explanation="两边先减去3，再除以2。",
        )
        save_json(
            output / "B6-photo-confirmed.json",
            call(
                "post",
                f"/mistakes/{captured['id']}/confirm",
                {"question": qdraft, "error_cause": "移项计算错误"},
                author=True,
            ),
        )
        reviews = call("get", "/reviews")["items"]
        review = next(r for r in reviews if r["question_id"] == qid)
        revised = submit(
            qid,
            exam_answers[0]["answer"],
            "demo-review",
            review_id=review["id"],
            source_task_id="A-task-review",
        )
        # Immediate correction follows feedback containing the answer; it is assisted recall.
        rated = call("post", f"/reviews/{review['id']}/rate", {"attempt_id": revised["id"], "quality": 2})
        save_json(output / "B7-attempts.json", {"attempts": [wrong, correct, revised]})
        save_json(output / "B8-review.json", rated)
        save_json(output / "B8-snapshot.json", call("get", "/learning-snapshot"))
        events = call("get", "/api/v1/learning-events")
        save_json(output / "B8-events.json", events)
        # Each module supplies an actual HTTP error example, not fabricated JSON.
        call("post", "/materials", files={"file": ("bad.exe", b"not allowed")}, expected=415)
        badref = dict(one["source_refs"][0], quote="假引用")
        call("post", "/knowledge/concepts", {"title": "校验", "source_refs": [badref]}, expected=422)
        call("post", "/tutoring/ask", {"question": "提示", "question_id": qid, "mode": "hint"}, expected=422)
        call("post", "/lessons", {"concept_ids": ["missing"]}, expected=404)
        call("post", "/exams", {"blueprint_id": "missing"}, expected=404)
        call(
            "post",
            "/attempts",
            {"question_id": qid, "answer": "0", "practice_session_id": "missing"},
            expected=422,
        )
        call("get", "/api/v1/learning-events?cursor=-1", expected=422)
        save_json(output / "requests-and-responses.json", requests)
        save_json(output / "error-examples.json", errors)
        save_json(
            root / "contracts/examples.json",
            dict(
                lesson=lesson,
                attempt=correct,
                candidate=call("get", "/learning-snapshot")["candidates"][0],
                event=events["items"][0],
                job=call("get", "/jobs/" + lesson_job["job_id"]),
                errors=errors,
            ),
        )
        save_json(
            output / "manifest.json",
            dict(
                runtime_dir=str(runtime),
                modules=[f"B{i}" for i in range(1, 9)],
                events=len(events["items"]),
                lesson_pages=len(lesson["pages"]),
                exam_questions=len(exam["items"]),
                http_checks=len(requests) + len(errors),
                model="offline; remote model not invoked",
            ),
        )
    print(json.dumps({"output": str(output), "checks": len(requests) + len(errors)}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="output/demo")
    main(parser.parse_args().output)
