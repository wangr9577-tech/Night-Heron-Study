"""Course-scoped reviewer access. The actor and the student's storage scope stay distinct."""

import json

from .errors import DomainError, require


def review_target(engine, c, course, kind, entity_id, reviewer=None):
    # Callers MUST already require the corresponding reviewer/author role for this course.
    row = c.execute(
        "SELECT user_id,data FROM b_entities WHERE id=? AND course_id=? AND kind=?",
        (entity_id, course, kind),
    ).fetchone()
    require(row is not None, "NOT_FOUND", "待审核对象不存在", 404)
    owner = row["user_id"]
    require(reviewer is None or reviewer != owner, "SELF_REVIEW_FORBIDDEN", "不能审核自己的学习记录", 403)
    engine.access.require_course_access(owner, course)
    return (owner, course), json.loads(row["data"])


def review_queue(engine, c, course, kind, status, reviewer=None):
    items = []
    rows = c.execute(
        """SELECT id FROM b_entities WHERE course_id=? AND kind=?
        AND json_extract(data,'$.status')=? ORDER BY rowid""",
        (course, kind, status),
    ).fetchall()
    for row in rows:
        try:
            scope, entity = review_target(engine, c, course, kind, row["id"], reviewer=reviewer)
        except DomainError as exc:
            if exc.status == 403:
                continue
            raise
        items.append(dict(entity, user_id=scope[0]))
    return items
