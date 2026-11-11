import json

import httpx
from conftest import api

from backend.tutoring.model import GroundedModel


def test_optional_model_uses_real_sources_and_server_configuration(client, content):
    def handler(request):
        payload = json.loads(request.content)
        context = json.loads(payload["messages"][1]["content"])
        cid = context["material"][0]["chunk_id"]
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "content": json.dumps(
                                {
                                    "answer": "先从等式两边减去常数项，再除以非零系数。",
                                    "citation_chunk_ids": [cid],
                                },
                                ensure_ascii=False,
                            )
                        }
                    }
                ]
            },
        )

    client.app.state.learning_engine.model = GroundedModel(
        "http://model.test/v1/chat/completions", "test", transport=httpx.MockTransport(handler)
    )
    reply = api(client, "post", "/tutoring/ask", json={"question": "一元一次方程如何求解"})
    assert reply["generated_by_model"] and reply["sources"] and reply["method"] == "retrieval_model"


def test_model_fabricated_citations_rejected(client, content):
    def handler(request):
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "content": json.dumps(
                                {"answer": "模型生成说明", "citation_chunk_ids": ["invented-chunk"]}
                            )
                        }
                    }
                ]
            },
        )

    client.app.state.learning_engine.model = GroundedModel(
        "http://model.test/chat", "test", transport=httpx.MockTransport(handler)
    )
    r = client.post("/api/v1/courses/course-demo/tutoring/ask", json={"question": "一元一次方程"})
    assert r.status_code == 502 and r.json()["error"]["code"] == "INVALID_MODEL_CITATIONS"
