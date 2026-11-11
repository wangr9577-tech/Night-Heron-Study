from fastapi import APIRouter, Depends

from backend.engine.context import course_context, get_engine
from backend.engine.errors import require
from backend.materials.service import validate_refs
from contracts.models import ConceptCreate, ConceptPatch, EdgeCreate, EdgePatch, GraphExtract

from .service import create_concept, create_edge, extract, normalize_title, update_edge

router = APIRouter(prefix="/api/v1/courses/{course_id}", tags=["B2 知识图谱"])


@router.post("/knowledge/extract")
def extract_graph(body: GraphExtract, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        return {"nodes": extract(engine, c, *ctx, body.material_ids), "method": "source_rule_extraction"}


@router.get("/knowledge")
def graph(ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.connect() as c:
        return {"nodes": engine.db.list(c, *ctx, "concept"), "edges": engine.db.list(c, *ctx, "edge")}


@router.post("/knowledge/concepts", status_code=201)
def add_concept(body: ConceptCreate, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        return create_concept(engine, c, *ctx, body.title, body.description, body.source_refs)


@router.patch("/knowledge/concepts/{concept_id}")
def patch_concept(
    concept_id: str, body: ConceptPatch, ctx=Depends(course_context), engine=Depends(get_engine)
):
    with engine.db.transaction() as c:
        concept = engine.db.get(c, *ctx, "concept", concept_id)
        if body.title:
            require(normalize_title(body.title), "INVALID_TITLE", "知识点标题不能为空", 422)
            require(
                not any(
                    n["id"] != concept_id and normalize_title(n["title"]) == normalize_title(body.title)
                    for n in engine.db.list(c, *ctx, "concept")
                ),
                "DUPLICATE_CONCEPT",
                "该标题已存在",
                409,
            )
        values = body.model_dump(exclude_none=True)
        if "source_refs" in values:
            values["source_refs"] = validate_refs(engine, c, *ctx, values["source_refs"])
        concept.update(values)
        concept["revision"] += 1
        engine.db.bump(c, *ctx)
        return engine.db.put(c, *ctx, "concept", concept)


@router.delete("/knowledge/concepts/{concept_id}")
def delete_concept(concept_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        engine.db.get(c, *ctx, "concept", concept_id)
        used = any(
            concept_id in str(e)
            for kind in ["question", "lesson", "attempt", "blueprint", "mistake"]
            for e in engine.db.list(c, *ctx, kind)
        )
        require(not used, "CONCEPT_IN_USE", "知识点已有业务引用，不能删除", 409)
        for edge in engine.db.list(c, *ctx, "edge"):
            if concept_id in [edge["from_id"], edge["to_id"]]:
                c.execute("DELETE FROM b_entities WHERE id=?", (edge["id"],))
        c.execute("DELETE FROM b_entities WHERE id=?", (concept_id,))
        engine.db.bump(c, *ctx)
        return {"deleted": True}


@router.post("/knowledge/edges", status_code=201)
def edge(body: EdgeCreate, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        return create_edge(engine, c, *ctx, body.from_id, body.to_id, body.type)


@router.patch("/knowledge/edges/{edge_id}")
def patch_edge(edge_id: str, body: EdgePatch, ctx=Depends(course_context), engine=Depends(get_engine)):
    changes = body.model_dump(exclude_none=True)
    require(changes, "EMPTY_PATCH", "请提供要修改的关系字段", 422)
    with engine.db.transaction() as c:
        return update_edge(engine, c, *ctx, edge_id, changes)


@router.delete("/knowledge/edges/{edge_id}")
def delete_edge(edge_id: str, ctx=Depends(course_context), engine=Depends(get_engine)):
    with engine.db.transaction() as c:
        engine.db.get(c, *ctx, "edge", edge_id)
        c.execute("DELETE FROM b_entities WHERE id=?", (edge_id,))
        engine.db.bump(c, *ctx)
        return {"deleted": True}
