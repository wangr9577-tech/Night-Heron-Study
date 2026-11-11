import re

from backend.lessons.service import source_for_display, split_for_display
from backend.materials.service import source_ref, validate_refs
from tests.conftest import api, finish


def test_long_english_and_extracted_table_preserve_words_and_lines():
    source = (
        "Classification metrics are meaningful when the evaluation set is independent. " * 3
        + "\nMetric\nFormula\nInterpretation\nAccuracy\n(TP + TN)/m\nFraction correct.\n"
        + "Recall\nTP/(TP + FN)\nFraction of actual positives found."
    )
    pieces = split_for_display(source)
    assert re.sub(r"\s+", " ", " ".join(pieces)).strip() == re.sub(r"\s+", " ", source).strip()
    assert all(len(piece.splitlines()) <= 3 for piece in pieces)
    assert all(
        not (a[-1].isalpha() and b[0].isalpha() and (a + " " + b).replace(" ", "") in source)
        for a, b in zip(pieces, pieces[1:], strict=False)
    )
    assert any("\n" in piece for piece in pieces)
    assert " ".join(pieces).index("Accuracy") < " ".join(pieces).index("Recall")


def test_clipped_reference_extends_with_verified_adjacent_offsets(client):
    content = (
        "# Accuracy\n\n" + "a" * 786 + " classification metric records correct predictions.\n"
        "Metric\nFormula\nAccuracy\n(TP + TN)/m\nRecall\nTP/(TP + FN)\n"
    ).encode()
    upload = api(client, "post", "/materials", files={"file": ("metric.md", content, "text/markdown")})
    finish(client, upload["job"])
    engine = client.app.state.learning_engine
    user, course = "user-demo", "course-demo"
    with engine.db.connect() as c:
        material = engine.db.get(c, user, course, "material", upload["material_id"])
        first = next(chunk for chunk in material["chunks"] if len(chunk["text"]) == 800)
        ref = source_ref(material, first)
        value, refs = source_for_display(engine, c, user, course, ref)
        assert ref["quote"].endswith("classificatio")
        assert value.endswith("classification")
        assert len(refs) == 2
        assert "".join(r["quote"] for r in refs) == value
        assert validate_refs(engine, c, user, course, refs) == refs


def test_lesson_and_ppt_keep_table_lines(client, content):
    _, concept, _ = content
    lesson_job = api(client, "post", "/lessons", json={"title": "原文讲解", "concept_ids": [concept["id"]]})
    lesson_id = finish(client, lesson_job)["id"]
    lesson = api(client, "get", "/lessons/" + lesson_id)
    texts = [e["text"] for page in lesson["pages"] for e in page["elements"]]
    assert all(len(t.splitlines()) <= 3 for t in texts)
    for page in lesson["pages"]:
        assert [x["text"] for x in page["elements"]] == [x["text"] for x in page["narration_segments"]]
    assert client.get(f"/api/v1/courses/course-demo/lessons/{lesson_id}/pptx").status_code == 200


def test_lesson_keeps_readable_content_when_one_concept_cannot_produce_a_question(client, content):
    _, existing, _ = content
    text = "这是一个需要后续补充的简短课堂记录"
    uploaded = api(client, "post", "/materials", files={"file": ("brief.txt", text.encode(), "text/plain")})
    finish(client, uploaded["job"])
    material = api(client, "get", "/materials/" + uploaded["material_id"])
    ref = source_ref(material, material["chunks"][0])
    brief = api(
        client,
        "post",
        "/knowledge/concepts",
        headers={"Authorization": "Bearer author-token"},
        json={"title": "暂缺材料的主题", "source_refs": [ref]},
    )
    job = api(client, "post", "/lessons", json={"title": "课程", "concept_ids": [existing["id"], brief["id"]]})
    lesson = api(client, "get", "/lessons/" + finish(client, job)["id"])
    assert any(text in e["text"] for p in lesson["pages"] for e in p["elements"])
    assert lesson["outline"][0]["question_ids"]
    assert lesson["outline"][1]["question_ids"] == []
    assert [(w["concept_id"], w["code"]) for w in lesson["generation_warnings"]] == [
        (brief["id"], "INSUFFICIENT_SOURCE")
    ]
