"""Check the delivered contract examples and generated files against each other."""

import hashlib
import json
from pathlib import Path
from xml.etree import ElementTree

import pymupdf
from pptx import Presentation

from backend.materials.service import display_text
from contracts.models import AttemptResult, Candidate, Job, LearningEvent, Lesson


def main():
    root = Path(__file__).resolve().parents[1]
    samples = root / "output/demo"

    def read(path):
        return json.loads(path.read_text(encoding="utf-8"))

    contract = read(root / "contracts/examples.json")
    for name, model in [
        ("lesson", Lesson),
        ("attempt", AttemptResult),
        ("candidate", Candidate),
        ("event", LearningEvent),
        ("job", Job),
    ]:
        model.model_validate(contract[name])
    materials = {}
    for path in samples.glob("B1-*.json"):
        data = read(path)
        if "pages" in data:
            materials[data["id"]] = data
    references = 0

    def walk(value):
        nonlocal references
        if isinstance(value, dict):
            if {"material_id", "chunk_id", "page", "quote", "start", "end"} <= value.keys():
                material = materials[value["material_id"]]
                assert value["chunk_id"] in {c["chunk_id"] for c in material["chunks"]}
                assert (
                    material["pages"][value["page"] - 1]["text"][value["start"] : value["end"]]
                    == value["quote"]
                )
                references += 1
            for inner in value.values():
                walk(inner)
        elif isinstance(value, list):
            for inner in value:
                walk(inner)

    for path in samples.glob("B*.json"):
        walk(read(path))
    lesson = read(samples / "B4-lesson.json")
    ppt = Presentation(str(samples / "B4-lesson.pptx"))
    assert len(lesson["pages"]) == len(ppt.slides)
    for page, slide in zip(lesson["pages"], ppt.slides, strict=True):
        texts = "\n".join(shape.text for shape in slide.shapes if shape.has_text_frame)
        element_ids = {element["element_id"] for element in page["elements"]}
        assert all(element["text"] in texts for element in page["elements"])
        assert all(
            set(segment["highlight_element_ids"]) <= element_ids for segment in page["narration_segments"]
        )
    exam = read(samples / "B5-exam.json")
    questions = read(samples / "B5-answer-key.json")["questions"]
    assert [i["question_id"] for i in exam["items"]] == [q["id"] for q in questions]
    assert len({q["prompt"] for q in questions}) == len(questions)
    assert all(q["verification"]["verified"] for q in questions)
    for q in questions:
        if q["kind"] == "cloze":
            assert any(q["answer"] in display_text(ref["quote"]) for ref in q["source_refs"])
    with pymupdf.open(samples / "B5-paper.pdf") as paper, pymupdf.open(samples / "B5-answers.pdf") as answers:
        paper_text = "".join(page.get_text() for page in paper)
        assert "参考答案" not in paper_text and "答案：" not in paper_text
        assert "参考答案" in "".join(page.get_text() for page in answers)
        pdf_counts = dict(paper=len(paper), answers=len(answers))
    events = read(samples / "B8-events.json")["items"]
    assert len({e["event_id"] for e in events}) == len(events)
    for event in events:
        LearningEvent.model_validate(event)
    xml = ElementTree.parse(root / "output/verification/tests.xml").getroot()
    suites = list(xml.iter("testsuite"))
    totals = {k: sum(int(s.get(k, 0)) for s in suites) for k in ["tests", "failures", "errors", "skipped"]}
    assert totals["failures"] == totals["errors"] == totals["skipped"] == 0
    render = read(samples / "render-report.json")
    assert render["slide_count"] == len(lesson["pages"]) and render["all_images_verified"]
    updated_validation = root / "output/verification/pptx-validation-review-fixes.json"
    validation = read(
        updated_validation
        if updated_validation.is_file()
        else root / "output/verification/pptx-validation-release.json"
    )
    # Validator receipts may wrap the final values under a result object in future versions.
    expected_hash = validation.get("finalSha256") or validation.get("final_sha256")
    if expected_hash:
        assert expected_hash == hashlib.sha256((samples / "B4-lesson.pptx").read_bytes()).hexdigest()
    result = dict(
        all_passed=True,
        tests=totals,
        verified_source_references=references,
        material_count=len(materials),
        lesson_pages=len(lesson["pages"]),
        exam_questions=len(questions),
        pdf_pages=pdf_counts,
        event_count=len(events),
        renderer=render,
        real_model_service_tested=False,
        a_backend_integration_tested=False,
    )
    (root / "output/verification/delivery-checks.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
