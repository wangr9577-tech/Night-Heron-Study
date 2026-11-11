import pytest
from fastapi.testclient import TestClient

from backend.app import create_app
from backend.engine.config import Settings

SOURCE = """# 一元一次方程

一元一次方程：只含一个未知数且未知数的次数为一的方程。一般形式为 ax + b = c，其中 a 不为零。
解一元一次方程时，等式两边同时减去 b，再同时除以 a。最后把得到的解代回原方程检验。
等式两边同时加上或减去同一个数，等式仍然成立。等式两边同时乘以或除以同一个非零数，等式仍然成立。

# 算术平均数

算术平均数：全部观测值的总和除以观测值个数，也称算术均值。
算术平均数描述数据的集中位置。计算时需要保留所有观测值，并准确计算样本个数。

# 学习检验

学习检验：通过独立作答验证对知识点的理解。观看讲解后仍应独立练习。
"""


@pytest.fixture
def client(tmp_path):
    app = create_app(Settings(data_dir=tmp_path / "data", mode="demo", worker_enabled=False))
    with TestClient(app) as client:
        client.headers.update({"Authorization": "Bearer demo-token"})
        yield client


def api(client, method, route, **kwargs):
    response = getattr(client, method)("/api/v1/courses/course-demo" + route, **kwargs)
    assert response.status_code < 300, (route, response.status_code, response.text)
    return response.json()


def finish(client, job):
    queue = client.app.state.learning_engine.queue
    for _ in range(30):
        current = api(client, "get", "/jobs/" + job["job_id"])
        if current["status"] in ["failed", "succeeded"]:
            assert current["status"] == "succeeded", current
            return current["result_ref"]
        queue.run_one()
    raise AssertionError("Job did not finish")


@pytest.fixture
def content(client):
    result = api(client, "post", "/materials", files={"file": ("教材.md", SOURCE.encode(), "text/markdown")})
    finish(client, result["job"])
    material = api(client, "get", "/materials/" + result["material_id"])
    graph = api(client, "post", "/knowledge/extract", json={"material_ids": [material["id"]]})
    concept = next(n for n in graph["nodes"] if n["title"] == "一元一次方程")
    mean = next(n for n in graph["nodes"] if n["title"] == "算术平均数")
    return material, concept, mean


def question(client, concept, kind="numeric", **overrides):
    body = dict(
        kind=kind,
        prompt="解方程 2x+3=11，填写 x 的值。",
        answer="4",
        concept_ids=[concept["id"]],
        source_refs=concept["source_refs"],
        explanation="两边减去 3，再同时除以 2，得到 x=4。",
        initial_difficulty="easy",
        rubric=["正确移项", "求解并代回检验"],
    )
    body.update(overrides)
    q = api(client, "post", "/questions", json=body, headers={"Authorization": "Bearer author-token"})
    # This helper supplies controlled pre-existing questions for the grading tests.
    # The public author endpoint itself is tested separately as untrusted self-authored content.
    engine = client.app.state.learning_engine
    with engine.db.transaction() as c:
        q = engine.db.get(c, "user-demo", "course-demo", "question", q["id"])
        q["origin"] = "test_fixture"
        engine.db.put(c, "user-demo", "course-demo", "question", q)
    return q


def attempt(client, qid, answer, key="a1", **kwargs):
    session = api(client, "post", f"/questions/{qid}/sessions")
    return api(
        client,
        "post",
        "/attempts",
        json=dict(question_id=qid, answer=answer, practice_session_id=session["id"], **kwargs),
        headers={"Idempotency-Key": key},
    )
