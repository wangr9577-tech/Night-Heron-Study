import hashlib

from backend.engine.db import dumps, now, uid
from backend.engine.errors import require

from .questions import grade
from .support import recent_support


def new_session(engine, c, user, course, question_id):
    engine.db.get(c, user, course, "question", question_id)
    records, exposed, _ = recent_support(engine, c, user, course, question_id)
    return engine.db.put(
        c,
        user,
        course,
        "practice_session",
        dict(
            id=uid("session"),
            question_id=question_id,
            hint_records=records,
            solution_viewed=exposed,
            submitted=False,
            created_at=now(),
        ),
    )


def settle(engine, c, user, course, attempt, question, score, rationale, method):
    require(attempt["status"] != "graded", "ALREADY_GRADED", "作答已经判定", 409)
    attempt.update(
        status="graded",
        score=score,
        grading_rationale=rationale,
        grading_method=method,
        graded_at=now(),
        rubric=question.get("rubric", []),
        answer=question["answer"],
        explanation=question["explanation"],
        source_refs=question["source_refs"],
    )
    # Authored questions belong to the same account that chose their answer key.
    # They remain useful for practice, but cannot establish that author's mastery or rewards.
    self_authored = question.get("origin") == "authored"
    # A solution read before answering supplies no mastery evidence. Hints reduce evidence weight.
    hint_level = max((h.get("level") or 0 for h in attempt["hint_records"]), default=0)
    assisted = attempt["solution_viewed"]
    weight = 0.0 if self_authored or assisted or attempt.get("recent_repeat") else max(0.4, 1 - 0.2 * hint_level)
    attempt["evidence_weight"] = weight
    if self_authored:
        attempt["evidence_exclusion_reason"] = "self_authored_question"
    engine.db.put(c, user, course, "attempt", attempt)
    for cid in ([] if self_authored else question["concept_ids"]):
        state_key = "state_" + hashlib.sha256(f"{user}:{course}:{cid}".encode()).hexdigest()[:24]
        states = engine.db.list(c, user, course, "mastery")
        state = next(
            (s for s in states if s["concept_id"] == cid),
            dict(
                id=state_key,
                concept_id=cid,
                alpha=1.0,
                beta=1.0,
                evidence_ids=[],
                graded_count=0,
                independent_correct_count=0,
            ),
        )
        state["alpha"] += score * weight
        state["beta"] += (1 - score) * weight
        state["graded_count"] += 1
        if score == 1 and weight == 1 and hint_level == 0:
            state["independent_correct_count"] += 1
        state["evidence_ids"].append(attempt["id"])
        state["mastery"] = round(state["alpha"] / (state["alpha"] + state["beta"]), 4)
        state["status"] = (
            "mastered"
            if state["mastery"] >= 0.8 and state["independent_correct_count"] >= 3
            else "learning"
            if state["mastery"] >= 0.5
            else "weak"
        )
        state["updated_at"] = now()
        engine.db.put(c, user, course, "mastery", state)
    if score < 1:
        mistakes = engine.db.list(c, user, course, "mistake")
        mistake = next((m for m in mistakes if m.get("question_id") == question["id"]), None)
        if not mistake:
            mistake = dict(
                id=uid("mistake"),
                question_id=question["id"],
                concept_ids=question["concept_ids"],
                original_answer=attempt["submitted_answer"],
                original_question=question["prompt"],
                status="confirmed",
                attempt_ids=[],
                variant_ids=[],
                source_refs=question["source_refs"],
                error_cause="答案与标准不符，具体错因待学习者确认",
                created_at=now(),
            )
        if attempt["id"] not in mistake["attempt_ids"]:
            mistake["attempt_ids"].append(attempt["id"])
        engine.db.put(c, user, course, "mistake", mistake)
    # All outcomes (lesson/variant/exam) feed the SAME review record for this question.
    from backend.review.service import ensure_review

    ensure_review(engine, c, user, course, question, attempt)
    engine.db.event(
        c,
        user,
        course,
        "practice_graded",
        {
            "attempt_id": attempt["id"],
            "question_id": question["id"],
            "score": score,
            "evidence_weight": weight,
            "task_requirement_met": None,
        },
        attempt.get("source_task_id"),
        event_id=attempt["id"] + ":graded",
    )
    engine.db.bump(c, user, course)
    return attempt


def submit(engine, c, user, course, body, key):
    require(key, "IDEMPOTENCY_REQUIRED", "作答提交需要 Idempotency-Key", 422)
    digest = hashlib.sha256(dumps(body.model_dump()).encode()).hexdigest()
    existing = c.execute(
        """SELECT * FROM b_idempotency WHERE user_id=? AND course_id=?
        AND scope='attempt' AND key=?""",
        (user, course, key),
    ).fetchone()
    if existing:
        require(existing["request_hash"] == digest, "IDEMPOTENCY_CONFLICT", "相同幂等键对应不同作答", 409)
        return engine.db.get(c, user, course, "attempt", existing["entity_id"])
    question = engine.db.get(c, user, course, "question", body.question_id)
    session = engine.db.get(c, user, course, "practice_session", body.practice_session_id)
    require(
        session["question_id"] == body.question_id and not session["submitted"],
        "SESSION_ALREADY_SUBMITTED",
        "会话不匹配或已提交，请新建会话",
        409,
    )
    if body.review_id:
        review = engine.db.get(c, user, course, "review", body.review_id)
        require(review["question_id"] == body.question_id, "REVIEW_MISMATCH", "复习项目与题目不匹配", 422)
    if body.exam_id:
        exam = engine.db.get(c, user, course, "exam", body.exam_id)
        require(
            body.question_id in [item["question_id"] for item in exam["items"]],
            "EXAM_MISMATCH",
            "题目不属于本试卷",
            422,
        )
    records, exposed, repeated = recent_support(engine, c, user, course, body.question_id)
    attempt = dict(
        id=uid("attempt"),
        attempt_id=None,
        question_id=body.question_id,
        concept_ids=question["concept_ids"],
        submitted_answer=body.answer,
        source_task_id=body.source_task_id,
        review_id=body.review_id,
        exam_id=body.exam_id,
        practice_session_id=body.practice_session_id,
        hint_records=records,
        solution_viewed=exposed,
        recent_repeat=repeated,
        status="submitted",
        score=None,
        created_at=now(),
        request_hash=digest,
    )
    attempt["attempt_id"] = attempt["id"]
    engine.db.put(c, user, course, "attempt", attempt)
    engine.db.event(
        c,
        user,
        course,
        "practice_submitted",
        {"attempt_id": attempt["id"], "question_id": question["id"], "task_requirement_met": None},
        body.source_task_id,
        attempt["id"] + ":submitted",
    )
    score, rationale, method = grade(question, body.answer)
    if score is None:
        attempt.update(status="pending_review", grading_rationale=rationale, grading_method=method)
        engine.db.put(c, user, course, "attempt", attempt)
    else:
        attempt = settle(engine, c, user, course, attempt, question, score, rationale, method)
    session.update(submitted=True, attempt_id=attempt["id"])
    engine.db.put(c, user, course, "practice_session", session)
    c.execute(
        "INSERT INTO b_idempotency VALUES(?,?,'attempt',?,?,?)", (user, course, key, digest, attempt["id"])
    )
    return attempt
