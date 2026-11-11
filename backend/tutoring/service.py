import math
import re
from collections import Counter
from contextlib import closing

from backend.engine.db import now, uid
from backend.engine.errors import require
from backend.materials.service import source_ref


def tokens(text):
    words = re.findall(r"[a-zA-Z0-9_]+|[\u4e00-\u9fff]", text.lower())
    chinese = re.findall(r"[\u4e00-\u9fff]+", text)
    return words + [part[i : i + 2] for part in chinese for i in range(len(part) - 1)]


def search(engine, c, user, course, query, limit=5):
    docs = [(m, ch) for m in engine.db.list(c, user, course, "material") for ch in m["chunks"]]
    q = set(tokens(query))
    counts = [Counter(tokens(ch["text"])) for _, ch in docs]
    n = len(docs)
    avg = sum(sum(counter.values()) for counter in counts) / max(n, 1)
    scored = []
    for (material, chunk), counter in zip(docs, counts, strict=True):
        length = sum(counter.values())
        score = 0
        for token in q:
            tf = counter[token]
            if tf:
                df = sum(token in cnt for cnt in counts)
                score += (
                    math.log(1 + (n - df + 0.5) / (df + 0.5))
                    * tf
                    * 2.2
                    / (tf + 1.2 * (0.25 + 0.75 * length / max(avg, 1)))
                )
        if score:
            scored.append(dict(score=round(score, 6), text=chunk["text"], source=source_ref(material, chunk)))
    return sorted(scored, key=lambda row: -row["score"])[:limit]


def build_reply(engine, body, q=None, hits=None):
    if q:
        sources = (
            q["source_refs"]
            if body.mode == "solution"
            else [{k: v for k, v in ref.items() if k != "quote"} for ref in q["source_refs"]]
        )
        if body.mode == "hint":
            hints = q.get(
                "hints", ["先确定题目考察的知识点。", "对照资料中的定义与条件。", "按评分要点逐步推导。"]
            )
            text = hints[body.hint_level - 1]
        elif body.mode == "socratic":
            text = "你会先使用哪个条件？它与题目中的哪些已知量对应？"
        elif body.mode == "solution":
            text = q["explanation"] + "\n参考答案：" + q["answer"]
        else:
            text = "先识别条件，再按资料中的定义作答。需要帮助时可以逐级查看提示。"
    elif hits:
        sources = [hit["source"] for hit in hits]
        if body.mode in {"explain", "socratic", "solution"} and engine.model.enabled:
            text, sources = engine.model.explain(body.question, body.mode, hits)
        elif body.mode == "socratic":
            text = "请先从下列原文定位适用条件，并用自己的话解释它：\n" + hits[0]["text"][:300]
        elif body.mode == "hint":
            text = [
                "先找到定义及其适用条件。",
                "对照教材区分已知条件与需要证明的结论。",
                "把原文中的条件逐一对应到问题，再检查是否遗漏例外情况。",
            ][body.hint_level - 1]
        else:
            text = "教材中的相关说明：\n" + "\n\n".join(hit["text"] for hit in hits)
    else:
        return dict(
            answer="当前课程资料中未检索到可靠依据，请补充资料或调整问题。",
            sources=[],
            mode=body.mode,
            hint_level=body.hint_level if body.mode == "hint" else None,
            grounded=False,
            method="extractive_bm25",
        )
    generated = not q and engine.model.enabled and body.mode in {"explain", "socratic", "solution"}
    result = dict(
        id=uid("reply"),
        answer=text,
        sources=sources,
        mode=body.mode,
        hint_level=body.hint_level if body.mode == "hint" else None,
        grounded=True,
        method="retrieval_model" if generated else "extractive_bm25",
        generated_by_model=bool(generated),
        factual_verification="source_links_only" if generated else "verbatim",
    )
    return result


def ask(engine, user, course, body):
    if body.question_id:
        # No remote request in this branch. Assistance and submission serialize atomically.
        with engine.db.transaction() as c:
            q = engine.db.get(c, user, course, "question", body.question_id)
            require(body.practice_session_id, "SESSION_REQUIRED", "题目提示必须绑定练习会话", 422)
            session = engine.db.get(c, user, course, "practice_session", body.practice_session_id)
            require(
                session["question_id"] == q["id"] and not session["submitted"],
                "INVALID_SESSION",
                "会话不匹配或已提交",
                409,
            )
            result = build_reply(engine, body, q=q)
            session["hint_records"].append(
                dict(
                    mode=body.mode,
                    level=body.hint_level if body.mode == "hint" else None,
                    occurred_at=now(),
                    response_text=result["answer"],
                )
            )
            if body.mode == "solution":
                session["solution_viewed"] = True
            engine.db.put(c, user, course, "practice_session", session)
            return engine.db.put(c, user, course, "tutoring_reply", result)
    require(not body.practice_session_id, "QUESTION_REQUIRED", "练习会话必须同时指定题目", 422)
    with closing(engine.db.connect()) as c:
        hits = search(engine, c, user, course, body.question, 3)
    # The connection and its read snapshot end BEFORE waiting for an external model.
    result = build_reply(engine, body, hits=hits)
    engine.access.require_course_access(user, course)
    if result["grounded"]:
        with engine.db.transaction() as c:
            # The material must still be immutable after retrieval while the model was running.
            from backend.materials.service import validate_refs

            validate_refs(engine, c, user, course, result["sources"])
            engine.db.put(c, user, course, "tutoring_reply", result)
    return result
