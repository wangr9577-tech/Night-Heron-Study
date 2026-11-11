"""Server-owned cross-session support history, including data written by older releases."""

import hashlib
from datetime import datetime, timedelta

from backend.engine.db import dumps, now

EVIDENCE_COOLDOWN_HOURS = 24


def record_answer_view(engine, c, user, course, question_id, mode):
    key = "exposure_" + hashlib.sha256(f"{user}:{course}:{question_id}".encode()).hexdigest()[:24]
    engine.db.put(
        c,
        user,
        course,
        "answer_exposure",
        dict(id=key, question_id=question_id, mode=mode, occurred_at=now()),
    )


def recent_support(engine, c, user, course, question_id, at=None):
    timestamp = at or now()
    cutoff = (datetime.fromisoformat(timestamp) - timedelta(hours=EVIDENCE_COOLDOWN_HOURS)).isoformat()
    records = {}
    exposed = False
    repeated = False
    for view in engine.db.list(c, user, course, "answer_exposure"):
        if view["question_id"] == question_id and cutoff <= view["occurred_at"] <= timestamp:
            exposed = True
    for session in engine.db.list(c, user, course, "practice_session"):
        if session["question_id"] != question_id:
            continue
        for record in session["hint_records"]:
            if cutoff <= record["occurred_at"] <= timestamp:
                records[dumps(record)] = record
                exposed |= record["mode"] in {"solution", "source_view"}
    for attempt in engine.db.list(c, user, course, "attempt"):
        if attempt["question_id"] != question_id:
            continue
        repeated |= cutoff <= attempt["created_at"] <= timestamp
        # Graded feedback includes the reference answer and full explanation.
        if attempt.get("graded_at") and cutoff <= attempt["graded_at"] <= timestamp:
            exposed = True
    return sorted(records.values(), key=lambda r: r["occurred_at"]), exposed, repeated
