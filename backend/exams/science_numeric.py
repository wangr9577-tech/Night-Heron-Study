"""Verified numerical families for explicitly sourced introductory data science."""

import math
import random
import re
from fractions import Fraction


def generate_science(concept, difficulty, seed, ordinal):
    title = concept["title"].casefold()
    quote = "\n".join(ref["quote"] for ref in concept["source_refs"])
    normalized = re.sub(r"\s+", "", quote).casefold()
    rng = random.Random(seed + ordinal * 104729)
    families = [
        ("accuracy", r"accuracy|准确率", "tp+tn"),
        ("recall", r"recall|sensitivity|召回率", "tp+fn"),
        ("precision", r"precision|精确率|查准率", "tp+fp"),
    ]
    for family, pattern, denominator in families:
        if re.search(pattern, title) and re.search(pattern, quote, re.I) and denominator in normalized:
            tp, tn, fp, fn = [rng.randint(3, 25 if difficulty == "easy" else 70) for _ in range(4)]
            numerator, divisor = {
                "accuracy": (tp + tn, tp + tn + fp + fn),
                "recall": (tp, tp + fn),
                "precision": (tp, tp + fp),
            }[family]
            label = {
                "accuracy": "准确率 Accuracy",
                "recall": "召回率 Recall",
                "precision": "精确率 Precision",
            }[family]
            answer = str(Fraction(numerator, divisor))
            assert Fraction(answer) * divisor == numerator and 0 <= Fraction(answer) <= 1
            steps = [
                f"混淆矩阵计数为 TP={tp}, TN={tn}, FP={fp}, FN={fn}。",
                f"{label} 对应的分子为 {numerator}，分母为 {divisor}。",
                f"代入定义得到 {numerator}/{divisor} = {answer}。",
            ]
            return dict(
                kind="numeric",
                prompt=f"二分类混淆矩阵：TP={tp}，TN={tn}，FP={fp}，FN={fn}。计算{label}，请用分数或 0–1 小数作答。",
                answer=answer,
                explanation="\n".join(steps),
                steps=steps,
                rubric=steps[:2],
                hints=[
                    "先明确分母所对应的样本集合。",
                    "区分真实为正与预测为正。",
                    "代入教材给出的指标定义并约分。",
                ],
                verification=dict(
                    method="exact_confusion_matrix",
                    verified=True,
                    family=family,
                    tp=tp,
                    tn=tn,
                    fp=fp,
                    fn=fn,
                    numerator=numerator,
                    denominator=divisor,
                ),
            )
    if (
        re.search(r"euclidean|欧氏距离|欧几里得", title)
        and re.search(r"euclidean|欧氏距离|欧几里得", quote, re.I)
        and ("distance" in quote.casefold() or "距离" in quote)
    ):
        scale = rng.randint(1, 4 if difficulty == "easy" else 10)
        x, y = rng.randint(-8, 8), rng.randint(-8, 8)
        a, b = x + 3 * scale, y + 4 * scale
        answer = str(5 * scale)
        assert math.isclose(math.hypot(a - x, b - y), int(answer))
        steps = [
            f"两个坐标差为 {3 * scale} 和 {4 * scale}。",
            f"平方距离为 {(3 * scale) ** 2}+{(4 * scale) ** 2}={25 * scale * scale}。",
            f"欧氏距离为该值的平方根，即 {answer}。",
        ]
        return dict(
            kind="numeric",
            prompt=f"二维点 x=({x}, {y}) 与 z=({a}, {b}) 的欧氏距离是多少？",
            answer=answer,
            explanation="\n".join(steps),
            steps=steps,
            rubric=steps[:2],
            hints=["分别计算每个坐标的差。", "将两个坐标差平方后相加。", "最后开平方，距离取非负值。"],
            verification=dict(method="pythagorean_distance", verified=True, x=[x, y], z=[a, b]),
        )
    return None
