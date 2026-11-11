import hashlib
import math
from datetime import datetime, timedelta, timezone

from backend.engine.db import now
from backend.engine.errors import require


def sm2(repetitions, interval_days, ease_factor, quality):
    require(0 <= quality <= 5, "INVALID_QUALITY", "SM-2 质量分为 0–5", 422)
    old_ease = ease_factor
    ease_factor = max(1.3, ease_factor + 0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02))
    if quality < 3:
        return 0, 1, round(ease_factor, 4)
    interval = (
        1 if repetitions == 0 else 6 if repetitions == 1 else max(1, math.ceil(interval_days * old_ease))
    )
    return repetitions + 1, interval, round(ease_factor, 4)


def ensure_review(engine, c, user, course, question, attempt):
    existing = next(
        (r for r in engine.db.list(c, user, course, "review") if r["question_id"] == question["id"]), None
    )
    if existing:
        existing["latest_attempt_id"] = attempt["id"]
        # A newly wrong practice brings a future review forward without erasing SM-2 history.
        if attempt["score"] < 1:
            existing["suggested_due_at"] = min(existing["suggested_due_at"], now())
        return engine.db.put(c, user, course, "review", existing)
    key = "review_" + hashlib.sha256(f"{user}:{course}:{question['id']}".encode()).hexdigest()[:24]
    due = datetime.now(timezone.utc) + timedelta(days=1 if attempt["score"] == 1 else 0)
    return engine.db.put(
        c,
        user,
        course,
        "review",
        dict(
            id=key,
            question_id=question["id"],
            concept_ids=question["concept_ids"],
            repetitions=0,
            interval_days=0,
            ease_factor=2.5,
            suggested_due_at=due.isoformat(),
            latest_attempt_id=attempt["id"],
            history=[],
            rated_attempt_ids=[],
            created_at=now(),
        ),
    )


def rate(engine, c, user, course, review_id, body):
    review = engine.db.get(c, user, course, "review", review_id)
    if body.attempt_id in review["rated_attempt_ids"]:
        old = next(h for h in review["history"] if h["attempt_id"] == body.attempt_id)
        require(
            old["quality"] == body.quality, "IDEMPOTENCY_CONFLICT", "同一作答已使用另一质量分完成复习", 409
        )
        return review
    attempt = engine.db.get(c, user, course, "attempt", body.attempt_id)
    require(
        attempt["question_id"] == review["question_id"]
        and attempt["review_id"] == review_id
        and attempt["status"] == "graded",
        "REVIEW_EVIDENCE_REQUIRED",
        "需要此复习项目的一次已判定作答",
        422,
    )
    require(
        attempt["created_at"] >= review["suggested_due_at"],
        "REVIEW_NOT_DUE",
        "本次作答时尚未到建议复习时间",
        409,
    )
    last = review["history"][-1]["occurred_at"] if review["history"] else review["created_at"]
    require(attempt["created_at"] >= last, "STALE_REVIEW_EVIDENCE", "不能用旧作答推进新复习周期", 409)
    highest_hint = max((h.get("level") or 0 for h in attempt["hint_records"]), default=0)
    max_quality = (
        2
        if attempt["score"] < 1 or attempt["solution_viewed"] or attempt.get("recent_repeat")
        else 3
        if highest_hint
        else 5
    )
    require(
        body.quality <= max_quality,
        "QUALITY_EXCEEDS_EVIDENCE",
        f"当前作答证据支持的最高质量分为 {max_quality}",
        422,
    )
    reps, interval, ease = sm2(
        review["repetitions"], review["interval_days"], review["ease_factor"], body.quality
    )
    timestamp = now()
    review.update(
        repetitions=reps,
        interval_days=interval,
        ease_factor=ease,
        suggested_due_at=(datetime.now(timezone.utc) + timedelta(days=interval)).isoformat(),
        last_reviewed_at=timestamp,
    )
    review["rated_attempt_ids"].append(attempt["id"])
    review["history"].append(
        dict(
            attempt_id=attempt["id"],
            quality=body.quality,
            interval_days=interval,
            ease_factor=ease,
            occurred_at=timestamp,
        )
    )
    engine.db.put(c, user, course, "review", review)
    engine.db.event(
        c,
        user,
        course,
        "review_completed",
        dict(
            review_id=review_id,
            attempt_id=attempt["id"],
            quality=body.quality,
            suggested_due_at=review["suggested_due_at"],
            task_requirement_met=None,
        ),
        attempt.get("source_task_id"),
        event_id=attempt["id"] + ":review",
    )
    engine.db.bump(c, user, course)
    return review


def snapshot(engine, c, user, course):
    if not c.in_transaction:
        c.execute("BEGIN")  # The version and all states belong to one consistent read snapshot.
    concepts = engine.db.list(c, user, course, "concept")
    states = {s["concept_id"]: s for s in engine.db.list(c, user, course, "mastery")}
    prereqs = {}
    for edge in engine.db.list(c, user, course, "edge"):
        if edge["type"] == "prerequisite":
            prereqs.setdefault(edge["to_id"], []).append(edge["from_id"])
    generated = now()
    candidates, concept_states = [], []
    for concept in concepts:
        state = states.get(
            concept["id"], dict(concept_id=concept["id"], mastery=None, status="unseen", evidence_ids=[])
        )
        concept_states.append(dict(state, title=concept["title"]))
        blocked = [
            cid for cid in prereqs.get(concept["id"], []) if states.get(cid, {}).get("status") != "mastered"
        ]
        if state["status"] != "mastered" and not blocked:
            candidates.append(
                dict(
                    candidate_id="learn:" + concept["id"],
                    type="concept",
                    target_id=concept["id"],
                    estimated_minutes=10,
                    reason="尚未练习" if state["status"] == "unseen" else "作答证据显示需要巩固",
                    suggested_due_at=generated,
                )
            )
    for review in engine.db.list(c, user, course, "review"):
        if review["suggested_due_at"] <= generated:
            candidates.insert(
                0,
                dict(
                    candidate_id="review:" + review["id"],
                    type="review",
                    target_id=review["id"],
                    estimated_minutes=5,
                    reason="间隔复习已到期",
                    suggested_due_at=review["suggested_due_at"],
                ),
            )
    v = c.execute("SELECT version FROM b_versions WHERE user_id=? AND course_id=?", (user, course)).fetchone()
    return dict(
        user_id=user,
        course_id=course,
        state_version=v[0] if v else 0,
        concept_states=concept_states,
        candidates=candidates,
        generated_at=generated,
    )
