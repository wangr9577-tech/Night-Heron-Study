import re
import unicodedata

from backend.engine.db import now, uid
from backend.engine.errors import require
from backend.materials.service import source_ref, validate_refs


def normalize_title(title):
    return re.sub(r"[\W_]", "", unicodedata.normalize("NFKC", title)).casefold()


def create_concept(engine, c, user, course, title, description, refs, key=None):
    refs = validate_refs(engine, c, user, course, refs)
    normalized = normalize_title(title)
    require(normalized, "INVALID_TITLE", "知识点标题不能为空", 422)
    existing = next(
        (x for x in engine.db.list(c, user, course, "concept") if normalize_title(x["title"]) == normalized),
        None,
    )
    if existing:
        known = {r["chunk_id"] + str(r["start"]) for r in existing["source_refs"]}
        additional = [r for r in refs if r["chunk_id"] + str(r["start"]) not in known]
        existing["source_refs"].extend(additional)
        if additional:
            existing["revision"] += 1
            engine.db.bump(c, user, course)
        return engine.db.put(c, user, course, "concept", existing)
    entity = dict(
        id=key or uid("concept"),
        title=title,
        description=description,
        source_refs=refs,
        created_at=now(),
        revision=1,
    )
    engine.db.bump(c, user, course)
    return engine.db.put(c, user, course, "concept", entity)


def extract(engine, c, user, course, ids):
    """Auditable rule extractor: headings and definition patterns; no invented semantic edges."""
    nodes = []
    for mid in ids:
        material = engine.db.get(c, user, course, "material", mid)
        require(material["status"] == "ready", "MATERIAL_NOT_READY", "资料尚未解析完成", 409)
        for chunk in material["chunks"]:
            candidates = []
            lines = chunk["text"].splitlines()
            for line_index, line in enumerate(lines):
                line = line.strip()
                heading = re.match(
                    r"^(?:#{1,6}\s+|第[一二三四五六七八九十\d]+[章节]\s*|\d+(?:\.\d+)*[.、\s]+)(.{2,60})$",
                    line,
                )
                definition = re.match(
                    r"^([\w\u4e00-\u9fff ()（）-]{2,30}?)(?:是指|定义为|：|:)\s*(.+)$", line
                )
                if heading:
                    candidates.append((heading.group(1), line))
                elif definition:
                    finish = line_index + 1
                    # PDF layout wraps one paragraph across lines. Preserve conditions on continuation lines.
                    while finish < len(lines) and not re.match(
                        r"^(?:#{1,6}\s|第[一二三四五六七八九十\d]+[章节]|\d+[.、\s])|^[\w\u4e00-\u9fff ()（）-]{2,30}(?:是指|定义为|：|:)",
                        lines[finish].strip(),
                    ):
                        finish += 1
                    quote = "\n".join(lines[line_index:finish]).strip()
                    candidates.append((definition.group(1).strip(), quote))
            if not candidates:
                # Extract a real phrase as a provisional node instead of hallucinating a concept.
                candidates = [
                    (
                        chunk["chapter"] if chunk["chapter"] != "正文" else chunk["text"][:24],
                        chunk["text"][:300],
                    )
                ]
            for title, quote in candidates[:20]:
                node = create_concept(
                    engine, c, user, course, title[:100], quote, [source_ref(material, chunk, quote)]
                )
                nodes.append(node)
    # Explicit "X 的前提是 Y" and "X requires Y" relations only when both concepts exist.
    all_nodes = engine.db.list(c, user, course, "concept")
    by_title = {normalize_title(node["title"]): node for node in all_nodes}
    for mid in ids:
        material = engine.db.get(c, user, course, "material", mid)
        text = "\n".join(ch["text"] for ch in material["chunks"])
        for match in re.finditer(
            r"([^。；\n]{1,60}?)(?:的前提是| requires )([^。；\n]{1,60})(?:[。；\n]|$)", text
        ):
            target = by_title.get(normalize_title(match.group(1)))
            prior = by_title.get(normalize_title(match.group(2)))
            if target and prior and target["id"] != prior["id"]:
                create_edge(engine, c, user, course, prior["id"], target["id"], "prerequisite")
    return list({n["id"]: n for n in nodes}.values())


def _check_edge(engine, c, user, course, from_id, to_id, kind, exclude_id=None):
    engine.db.get(c, user, course, "concept", from_id)
    engine.db.get(c, user, course, "concept", to_id)
    require(from_id != to_id, "GRAPH_CYCLE", "不允许自环", 422)
    if kind == "related":
        from_id, to_id = sorted([from_id, to_id])
    edges = [edge for edge in engine.db.list(c, user, course, "edge") if edge["id"] != exclude_id]
    duplicate = next(
        (
            edge
            for edge in edges
            if edge["type"] == kind
            and (
                sorted([edge["from_id"], edge["to_id"]]) == [from_id, to_id]
                if kind == "related"
                else (edge["from_id"], edge["to_id"]) == (from_id, to_id)
            )
        ),
        None,
    )
    if duplicate:
        return from_id, to_id, duplicate
    if kind == "prerequisite":
        adjacency = {}
        for edge in edges:
            if edge["type"] == "prerequisite":
                adjacency.setdefault(edge["from_id"], []).append(edge["to_id"])
        todo, seen = [to_id], set()
        while todo:
            current = todo.pop()
            require(current != from_id, "GRAPH_CYCLE", "前置关系构成有向环", 422)
            if current not in seen:
                seen.add(current)
                todo.extend(adjacency.get(current, []))
    return from_id, to_id, None


def create_edge(engine, c, user, course, from_id, to_id, kind):
    from_id, to_id, duplicate = _check_edge(engine, c, user, course, from_id, to_id, kind)
    if duplicate:
        return duplicate
    # IDs are independent of mutable endpoints: editing an old hash-based ID cannot
    # cause a later creation of its former endpoints to overwrite the edited edge.
    key = uid("edge")
    engine.db.bump(c, user, course)
    return engine.db.put(c, user, course, "edge", dict(id=key, from_id=from_id, to_id=to_id, type=kind))


def update_edge(engine, c, user, course, edge_id, changes):
    old = engine.db.get(c, user, course, "edge", edge_id)
    new = dict(old, **changes)
    from_id, to_id, duplicate = _check_edge(
        engine, c, user, course, new["from_id"], new["to_id"], new["type"], exclude_id=edge_id
    )
    require(not duplicate, "DUPLICATE_EDGE", "相同关系已存在", 409)
    new.update(from_id=from_id, to_id=to_id)
    if new != old:
        engine.db.bump(c, user, course)
        engine.db.put(c, user, course, "edge", new)
    return new
