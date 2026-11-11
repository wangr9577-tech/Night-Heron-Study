from backend.exams.generator import generate


def test_english_table_rows_become_single_readable_cloze_questions():
    quote = (
        "Accuracy  (TP + TN)/m  Fraction of predictions that are correct.\n"
        "Error rate (FP + FN)/m Fraction wrong; 1 - accuracy.\n"
        "Recall  TP/(TP + FN)  Fraction of actual positives found.\n"
        "Precision  TP/(TP + FP)  Fraction of positive predictions that are correct."
    )
    concept = {"id": "accuracy", "title": "分类准确率 Accuracy", "source_refs": [{"quote": quote}]}
    for seed in range(30):
        question = generate(concept, "cloze", "medium", seed)
        assert question["prompt"].count("____") == 1
        assert len(question["prompt"]) < 180
        assert "  " not in question["prompt"]
        assert "Recall" not in question["prompt"]
        assert "Precision" not in question["prompt"]
        assert "Error rate" not in question["prompt"]
        assert question["answer"] in quote
        assert question["verification"]["verified"]


def test_repeated_term_is_masked_once():
    quote = "准确率用于衡量准确率的计算结果以及预测效果。"
    concept = {"id": "c", "title": "准确率", "source_refs": [{"quote": quote}]}
    question = generate(concept, "cloze", "easy", 1)
    assert question["prompt"].count("____") == 1
    assert "准确率" in question["prompt"]
