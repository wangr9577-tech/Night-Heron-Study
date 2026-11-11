import os

import pytest
from conftest import api, attempt, question
from PIL import Image, ImageDraw, ImageFont

from backend.assessment.questions import grade, numeric_value
from backend.engine.errors import DomainError
from backend.exams.generator import generate
from backend.materials.parser import parse_file
from backend.review.service import sm2


def test_sm2_reference_sequence_and_lapse():
    assert sm2(0, 0, 2.5, 5) == (1, 1, 2.6)
    assert sm2(1, 1, 2.6, 5) == (2, 6, 2.7)
    assert sm2(2, 6, 2.7, 4) == (3, 17, 2.7)
    assert sm2(3, 16, 2.7, 2) == (0, 1, 2.38)
    assert sm2(0, 1, 1.3, 0) == (0, 1, 1.3)


@pytest.mark.parametrize("answer", ["4", "4.0000001", "8/2", "x = 4", "４"])
def test_numeric_equivalent_answers(answer):
    score, _, _ = grade({"kind": "numeric", "answer": "4", "tolerance": 0.000001}, answer)
    assert score == 1


@pytest.mark.parametrize("answer", ["nan", "Infinity", "1/0", "__import__('os')", "", "1e9999"])
def test_invalid_numeric_no_execution(answer):
    with pytest.raises(DomainError):
        numeric_value(answer)


def test_generation_answers_independently_verified_over_seeds(client, content):
    _, con, mean = content
    from fractions import Fraction

    for i in range(100):
        q = generate(con, "numeric", "medium", i)
        v = q["verification"]
        assert v["a"] * Fraction(q["answer"]) + v["b"] == v["c"]
        q = generate(mean, "numeric", "easy", i)
        assert Fraction(q["answer"]) == Fraction(
            sum(q["verification"]["values"]), len(q["verification"]["values"])
        )


def test_bad_review_quality_cannot_override_wrong_answer(client, content):
    _, con, _ = content
    q = question(client, con)
    attempt(client, q["id"], "100")
    review = api(client, "get", "/reviews")["items"][0]
    again = attempt(client, q["id"], "100", key="review-wrong", review_id=review["id"])
    r = client.post(
        f"/api/v1/courses/course-demo/reviews/{review['id']}/rate",
        json={"attempt_id": again["id"], "quality": 5},
    )
    assert r.status_code == 422 and r.json()["error"]["code"] == "QUALITY_EXCEEDS_EVIDENCE"
    rated = api(
        client, "post", f"/reviews/{review['id']}/rate", json={"attempt_id": again["id"], "quality": 2}
    )
    assert rated["repetitions"] == 0


@pytest.mark.skipif(
    os.getenv("ZHUOZHI_TEST_OCR") != "true", reason="OCR integration enabled by check.ps1 -IncludeOCR"
)
def test_real_chinese_image_and_scanned_pdf_ocr(tmp_path):
    import pymupdf

    image = Image.new("RGB", (1100, 320), "white")
    font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 40)
    draw = ImageDraw.Draw(image)
    draw.text((45, 45), "一元一次方程", fill="black", font=font)
    draw.text((45, 120), "2x + 3 = 11", fill="black", font=font)
    png = tmp_path / "scan.png"
    image.save(png)
    pages = parse_file(png)
    assert "方程" in pages[0]["text"] and "11" in pages[0]["text"] and pages[0]["ocr_lines"]
    pdf = pymupdf.open()
    page = pdf.new_page(width=550, height=160)
    page.insert_image(page.rect, filename=str(png))
    target = tmp_path / "scan.pdf"
    pdf.save(target)
    parsed = parse_file(target)
    assert parsed[0]["method"] == "ocr" and "11" in parsed[0]["text"]
