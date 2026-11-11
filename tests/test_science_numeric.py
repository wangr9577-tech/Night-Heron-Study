"""Calculation families must agree with exact independently recomputed answers."""

from fractions import Fraction

import pytest

from backend.engine.errors import DomainError
from backend.exams.generator import generate


@pytest.mark.parametrize(
    ("title", "quote", "family"),
    [
        ("准确率 Accuracy", "Accuracy (TP + TN)/m; m = TP + TN + FP + FN.", "accuracy"),
        ("召回率 Recall", "Recall / sensitivity TP/(TP + FN).", "recall"),
        ("精确率 Precision", "Precision TP/(TP + FP).", "precision"),
    ],
)
def test_science_metrics_exact_and_source_bound(title, quote, family):
    concept = {"id": "concept", "title": title, "source_refs": [{"quote": quote}]}
    for seed in range(50):
        q = generate(concept, "numeric", "easy", seed)
        proof = q["verification"]
        tp, tn, fp, fn = (proof[k] for k in ("tp", "tn", "fp", "fn"))
        expected = {
            "accuracy": Fraction(tp + tn, tp + tn + fp + fn),
            "recall": Fraction(tp, tp + fn),
            "precision": Fraction(tp, tp + fp),
        }[family]
        assert Fraction(q["answer"]) == expected
        assert proof["verified"] and proof["family"] == family
    with pytest.raises(DomainError):
        generate(
            dict(concept, source_refs=[{"quote": "The lecture does not give any metric definition."}]),
            "numeric",
            "easy",
            0,
        )


def test_euclidean_distance_exact():
    concept = {
        "id": "distance",
        "title": "欧氏距离 Euclidean distance",
        "source_refs": [
            {"quote": "For numerical features, Euclidean distance is calculated from coordinate differences."}
        ],
    }
    for seed in range(50):
        q = generate(concept, "numeric", "easy", seed)
        x, z = q["verification"]["x"], q["verification"]["z"]
        assert int(q["answer"]) ** 2 == sum((a - b) ** 2 for a, b in zip(x, z, strict=True))
