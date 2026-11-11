import random
import re
from fractions import Fraction

from backend.engine.errors import DomainError, require
from backend.materials.service import display_text


def generate(concept, kind, difficulty, seed, ordinal=0, exclude=None):
    """Grounded offline generator. Numeric families require explicitly relevant source text.

    No LLM answer is accepted as mathematical verification. Unsupported numerical subjects
    return an actionable error rather than silently substituting an unrelated math problem.
    """
    rng = random.Random(seed + ordinal * 104729)
    refs = concept["source_refs"]
    quote = "\n".join(r["quote"] for r in refs)
    base = dict(
        concept_ids=[concept["id"]],
        source_refs=refs,
        initial_difficulty=difficulty,
        accepted_answers=[],
        options={},
        rubric=[],
        tolerance=0.000001,
    )
    if kind == "numeric":
        from backend.exams.science_numeric import generate_science

        science = generate_science(concept, difficulty, seed, ordinal)
        if science:
            return dict(base, **science)
        if re.search(r"一元一次方程|linear equation|ax\s*\+\s*b\s*=\s*c", quote, re.I):
            # Sample the solution first, derive c, then independently substitute the answer.
            a = rng.randint(2, 8 if difficulty == "easy" else 18)
            b = rng.randint(1, 12 if difficulty == "easy" else 40)
            x = rng.randint(1, 15)
            c = a * x + b
            prompt = f"解一元一次方程：{a}x + {b} = {c}。请填写 x 的值。"
            answer = str(Fraction(c - b, a))
            steps = [
                f"等式两边同时减去 {b}，得 {a}x = {c - b}。",
                f"两边同时除以非零系数 {a}，得 x = {answer}。",
                f"代回检验：{a} × {answer} + {b} = {c}。",
            ]
            require(
                a * Fraction(answer) + b == c, "ANSWER_VERIFICATION_FAILED", "方程答案未通过代入检验", 422
            )
            verification = dict(method="exact_fraction_substitution", verified=True, a=a, b=b, c=c)
            hints = [
                "先观察等式两边可以同时进行什么运算。",
                "先消去常数项，再处理未知数的系数。",
                "注意除法的系数必须非零，并代回检验。",
            ]
        elif re.search(r"算术平均|算术均值|arithmetic mean", quote, re.I):
            values = [rng.randint(2, 30) for _ in range(3 if difficulty == "easy" else 5)]
            answer = str(Fraction(sum(values), len(values)))
            prompt = f"计算数据 {', '.join(map(str, values))} 的算术平均数，可用分数作答。"
            steps = [
                f"样本个数 n = {len(values)}。",
                f"总和为 {sum(values)}。",
                f"算术平均数 = {sum(values)}/{len(values)} = {answer}。",
            ]
            require(
                Fraction(answer) * len(values) == sum(values),
                "ANSWER_VERIFICATION_FAILED",
                "均值校验失败",
                422,
            )
            verification = dict(method="exact_fraction_mean", verified=True, values=values)
            hints = ["先数清数据的个数。", "将所有数据相加。", "用总和除以数据的个数。"]
        else:
            raise DomainError(
                "UNSUPPORTED_NUMERIC_TOPIC", "此知识点尚无可靠的数值出题器，请改用 cloze 或导入审核题目", 422
            )
        return dict(
            base,
            kind="numeric",
            prompt=prompt,
            answer=answer,
            explanation="\n".join(steps),
            steps=steps,
            rubric=steps[:2],
            hints=hints,
            verification=verification,
        )
    # Treat extracted PDF rows as separate source fragments. Flattening the entire
    # table into one sentence produces unreadable questions with repeated blanks.
    choices, focused, heading_focused = [], [], []
    title_terms = re.findall(r"[A-Za-z][A-Za-z-]{2,30}|[\u4e00-\u9fff]{2,30}", concept["title"])
    stopwords = {
        "about",
        "after",
        "before",
        "between",
        "could",
        "other",
        "their",
        "there",
        "these",
        "those",
        "using",
        "where",
        "which",
        "while",
        "would",
    }
    for ref in refs:
        fragments = re.split(r"\n+|[。！？]|(?<!\d)\.(?=\s|$)", ref["quote"])
        for fragment in fragments:
            # PDF layout gaps are not semantic spacing in a phone-sized question.
            sentence = re.sub(r"[ \t]+", " ", display_text(fragment))
            sentence = sentence.strip().lstrip("# ")
            if not 12 <= len(sentence) <= 200:
                continue
            terms = []
            if concept["title"] in sentence:
                terms.append(concept["title"])
            terms.extend(term for term in title_terms if term.casefold() in sentence.casefold())
            terms.extend(
                term
                for term in ["非零数", "不为零", "未知数", "系数", "总和", "观测值个数", "移项"]
                if term in sentence
            )
            terms.extend(
                term
                for term in re.findall(r"[A-Za-z][A-Za-z-]{4,30}", sentence)
                if term.casefold() not in stopwords
            )
            terms.extend(re.findall(r"(?:称为|定义为|称作)[“\"']?([\u4e00-\u9fff]{2,12})", sentence))
            for term in dict.fromkeys(terms):
                if term and term != sentence and 1 < len(term) <= 30:
                    mask = (
                        re.compile(r"(?<![A-Za-z])" + re.escape(term) + r"(?![A-Za-z])", re.I)
                        if term.isascii()
                        else re.compile(re.escape(term))
                    )
                    match = mask.search(sentence)
                    if not match:
                        continue
                    answer = match.group()
                    prompt = (
                        "依据教材补全空缺："
                        + sentence[: match.start()]
                        + "____"
                        + sentence[match.end() :]
                        + "。"
                    )
                    if prompt not in (exclude or set()):
                        choice = (prompt, answer, sentence, ref)
                        choices.append(choice)
                        if any(t.casefold() in sentence.casefold() for t in title_terms):
                            focused.append(choice)
                        if any(sentence.casefold().startswith(t.casefold()) for t in title_terms):
                            heading_focused.append(choice)
    require(choices, "INSUFFICIENT_SOURCE", "资料中没有足够的独立句子用于生成新题，请补充资料或减少题量", 422)
    prompt, answer, sentence, ref = rng.choice(heading_focused or focused or choices)
    return dict(
        base,
        kind="cloze",
        prompt=prompt,
        answer=answer,
        source_refs=[ref],
        explanation="原文为：" + sentence + "。",
        rubric=["准确补出教材中的术语或表述"],
        steps=["识别句子所描述的对象与条件。", "对照原文确认空缺词。", "完整读回句子，检查含义。"],
        hints=[
            "先判断空缺在句子中的作用。",
            "回想本知识点的定义与适用条件。",
            "结合上下文确定需要填写的术语。",
        ],
        verification={"method": "exact_source_mask", "verified": answer in sentence},
    )
