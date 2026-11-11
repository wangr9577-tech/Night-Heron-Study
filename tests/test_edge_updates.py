import hashlib

from conftest import api


def test_edge_patch_validates_atomically_and_keeps_id(client, content):
    graph = api(client, "get", "/knowledge")
    a, b, c = [node["id"] for node in graph["nodes"][:3]]
    first = api(client, "post", "/knowledge/edges", json={"from_id": a, "to_id": b, "type": "prerequisite"})
    second = api(client, "post", "/knowledge/edges", json={"from_id": b, "to_id": c, "type": "prerequisite"})
    url = f"/api/v1/courses/course-demo/knowledge/edges/{first['id']}"
    before = api(client, "get", "/knowledge")
    version = api(client, "get", "/learning-snapshot")["state_version"]
    for body, status, code in [
        ({"from_id": c, "to_id": b}, 422, "GRAPH_CYCLE"),
        ({"from_id": b, "to_id": c}, 409, "DUPLICATE_EDGE"),
        ({"from_id": a, "to_id": a}, 422, "GRAPH_CYCLE"),
        ({"to_id": "not-owned"}, 404, "NOT_FOUND"),
        ({}, 422, "EMPTY_PATCH"),
    ]:
        response = client.patch(url, json=body)
        assert response.status_code == status, response.text
        assert response.json()["error"]["code"] == code
        assert api(client, "get", "/knowledge") == before
        assert api(client, "get", "/learning-snapshot")["state_version"] == version
    unchanged = client.patch(url, json={"to_id": b})
    assert unchanged.status_code == 200 and unchanged.json() == first
    assert api(client, "get", "/learning-snapshot")["state_version"] == version
    edited = client.patch(url, json={"to_id": c})
    assert edited.status_code == 200 and edited.json() == dict(first, to_id=c)
    assert api(client, "get", "/learning-snapshot")["state_version"] == version + 1
    assert second in api(client, "get", "/knowledge")["edges"]
    # Same endpoints may now be re-created without replacing the edited edge.
    replacement = api(
        client, "post", "/knowledge/edges", json={"from_id": a, "to_id": b, "type": "prerequisite"}
    )
    assert replacement["id"] != first["id"]
    assert edited.json() in api(client, "get", "/knowledge")["edges"]
    # No course access, or another member with their own isolated graph, can edit this edge.
    assert (
        client.patch(
            url, json={"type": "related"}, headers={"Authorization": "Bearer other-token"}
        ).status_code
        == 403
    )
    client.app.state.learning_engine.access.identities["peer-token"] = {
        "user_id": "peer",
        "course_ids": ["course-demo"],
    }
    assert (
        client.patch(
            url, json={"type": "related"}, headers={"Authorization": "Bearer peer-token"}
        ).status_code
        == 404
    )


def test_related_duplicates_and_legacy_hashed_id_are_safe(client, content):
    graph = api(client, "get", "/knowledge")
    a, b, c = [node["id"] for node in graph["nodes"][:3]]
    engine = client.app.state.learning_engine
    key = "edge_" + hashlib.sha256(f"user-demo:course-demo:{a}:{b}:prerequisite".encode()).hexdigest()[:24]
    legacy = dict(id=key, from_id=a, to_id=b, type="prerequisite")
    with engine.db.transaction() as db:
        engine.db.put(db, "user-demo", "course-demo", "edge", legacy)
    url = f"/api/v1/courses/course-demo/knowledge/edges/{key}"
    changed = client.patch(url, json={"type": "related", "to_id": c})
    assert changed.status_code == 200
    replacement = api(
        client, "post", "/knowledge/edges", json={"from_id": a, "to_id": b, "type": "prerequisite"}
    )
    assert replacement["id"] != key
    related = changed.json()
    assert related in api(client, "get", "/knowledge")["edges"]
    duplicate = api(client, "post", "/knowledge/edges", json={"from_id": c, "to_id": a, "type": "related"})
    assert duplicate["id"] == key
    # Reversing an undirected edge is an unchanged operation, never a duplicate.
    assert client.patch(url, json={"from_id": c, "to_id": a}).json() == related
