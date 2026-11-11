from conftest import api, finish

from backend.knowledge.service import extract
from backend.materials.parser import structure


def test_multiline_definition_retains_nonzero_condition(client):
    engine = client.app.state.learning_engine
    pages = [
        {
            "page": 1,
            "text": "# 一元一次方程\n\n一元一次方程：一般形式为 ax + b = c，其中 a\n不为零。\n\n解方程需要移项，然后除以非零系数，最后代回检\n验。",
            "method": "pdf_text",
            "ocr_lines": [],
        }
    ]
    chunks, chapters = structure("multiline", pages)
    with engine.db.transaction() as c:
        engine.db.put(
            c,
            "user-demo",
            "course-demo",
            "material",
            dict(id="multiline", status="ready", pages=pages, chunks=chunks, chapters=chapters),
        )
        nodes = extract(engine, c, "user-demo", "course-demo", ["multiline"])
    con = next(n for n in nodes if n["title"] == "一元一次方程")
    assert any("不为零" in r["quote"] for r in con["source_refs"])
    job = api(client, "post", "/lessons", json={"concept_ids": [con["id"]]})
    lid = finish(client, job)["id"]
    lesson = api(client, "get", "/lessons/" + lid)
    texts = [e["text"] for p in lesson["pages"] for e in p["elements"]]
    assert any("不为零" in t for t in texts)
    assert not any(t.startswith("#") or t == "验。" for t in texts)
