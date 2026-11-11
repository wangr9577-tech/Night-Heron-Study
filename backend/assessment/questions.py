import re
import unicodedata
from decimal import Decimal, InvalidOperation
from fractions import Fraction

from backend.engine.db import now, uid
from backend.engine.errors import DomainError, require
from backend.materials.service import validate_refs

PRIVATE_FIELDS = {"answer", "accepted_answers", "rubric", "explanation", "hints", "steps", "verification"}


def public_question(question):
    # Sources themselves can reveal cloze answers; deliver locators without quoted text pre-submission.
    result = {k: v for k, v in question.items() if k not in PRIVATE_FIELDS}
    result["source_refs"] = [{k: v for k, v in r.items() if k != "quote"} for r in question["source_refs"]]
    return result


def normalize_answer(value):
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", str(value))).casefold().strip("。.!！")


def numeric_value(value):
    value = unicodedata.normalize("NFKC", value).strip()
    if re.fullmatch(r"[a-zA-Z]\s*=.*", value):
        value = value.split("=", 1)[1].strip()
    require(len(value) <= 100, "INVALID_NUMERIC", "数值长度超过限制", 422)
    try:
        if "/" in value:
            left, right = value.split("/")
            left_value, right_value = Decimal(left.strip()), Decimal(right.strip())
            require(
                left_value.is_finite()
                and right_value.is_finite()
                and abs(left_value.adjusted()) <= 100
                and abs(right_value.adjusted()) <= 100,
                "INVALID_NUMERIC",
                "只接受有限范围内的分数",
                422,
            )
            result = Fraction(left_value) / Fraction(right_value)
        else:
            d = Decimal(value)
            require(d.is_finite() and abs(d.adjusted()) <= 100, "INVALID_NUMERIC", "只接受有限数值", 422)
            result = Fraction(d)
        require(
            abs(result.numerator) < 10**110 and result.denominator < 10**110,
            "INVALID_NUMERIC",
            "数值超出范围",
            422,
        )
        return result
    except (ValueError, InvalidOperation, ZeroDivisionError, OverflowError) as exc:
        raise DomainError("INVALID_NUMERIC", "请输入有限数值、小数或分数", 422) from exc


def create_question(engine, c, user, course, data, key=None, origin="authored"):
    data = data.model_dump() if hasattr(data, "model_dump") else dict(data)
    require(
        len(set(data["concept_ids"])) == len(data["concept_ids"]),
        "DUPLICATE_CONCEPT",
        "知识点 ID 不得重复",
        422,
    )
    for cid in data["concept_ids"]:
        engine.db.get(c, user, course, "concept", cid)
    refs = validate_refs(engine, c, user, course, data["source_refs"])
    if data["kind"] == "single_choice":
        require(
            2 <= len(data.get("options", {})) <= 8 and data["answer"] in data["options"],
            "INVALID_ANSWER",
            "选择题必须有 2–8 个选项且答案为选项键",
            422,
        )
    elif data["kind"] == "numeric":
        numeric_value(data["answer"])
    elif data["kind"] == "short_answer":
        require(data.get("rubric"), "RUBRIC_REQUIRED", "简答题需提供评分要点", 422)
    data.update(
        id=key or uid("q"),
        source_refs=refs,
        origin=origin,
        created_at=now(),
        difficulty={
            "initial": data.get("initial_difficulty", "medium"),
            "calibrated": False,
            "irt_parameters": None,
        },
    )
    return engine.db.put(c, user, course, "question", data)


def grade(question, answer):
    kind = question["kind"]
    if kind == "numeric":
        try:
            actual = numeric_value(answer)
        except DomainError:
            return 0.0, "数值格式无效，未满足数值答案要求。", "numeric_exact"
        expected = numeric_value(question["answer"])
        correct = abs(actual - expected) <= Fraction(str(question.get("tolerance", 0.000001)))
        return float(correct), "按数值与绝对容差校验。", "numeric_exact"
    accepted = [question["answer"]] + question.get("accepted_answers", [])
    correct = normalize_answer(answer) in {normalize_answer(x) for x in accepted}
    if kind == "short_answer" and not correct:
        return None, "开放作答等待人工按评分要点审核；尚不更新掌握状态。", "manual_required"
    return float(correct), "按选项键或规范化后的标准答案校验。", "exact_match"
