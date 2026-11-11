"""Real A/B identity integration and offline administrative review grants."""

import json
import os
import subprocess
import sys
from pathlib import Path

from backend.app import core
from backend.assessment.questions import create_question

pytest_plugins = ("backend.tests.test_integration_real",)


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "manage_review_permissions.py"


def admin(action, course, user=None, permission=None):
    command = [sys.executable, str(SCRIPT), "--database", str(core.DB_PATH), action, "--course", course]
    if user:
        command += ["--user", user, "--permission", permission]
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        env={**os.environ, "PYTHONIOENCODING": "utf-8"},
    )


def test_admin_grants_are_course_scoped_revocable_and_cannot_self_review(integrated):
    c, course, source, learning = integrated
    student_auth = c.headers["Authorization"]
    student = core.current_user(student_auth)
    new = c.post("/api/v1/auth/register", json={"username": "reviewer", "password": "password"}).json()
    reviewer = new["user"]["user_id"]
    teacher_auth = {"Authorization": "Bearer " + new["access_token"]}
    denied = admin("grant", course, reviewer, "content:write")
    assert denied.returncode != 0
    assert c.post(f"/api/v1/courses/{course}/members", json={"user_id": reviewer}).status_code == 200
    prefix = f"/api/v1/courses/{course}"
    with learning.db.transaction() as db:
        question = create_question(
            learning,
            db,
            student,
            course,
            dict(
                kind="short_answer",
                prompt="请解释均值",
                answer="均值的定义",
                explanation="总和除以个数。",
                rubric=["说明总和", "说明个数"],
                concept_ids=source["concept_ids"],
                source_refs=source["source_refs"],
            ),
        )
    sid = c.post(f"{prefix}/questions/{question['id']}/sessions").json()["id"]
    attempt = c.post(
        f"{prefix}/attempts",
        headers={"Idempotency-Key": "review-test-1"},
        json={"question_id": question["id"], "practice_session_id": sid, "answer": "一种不同表述"},
    ).json()
    assert attempt["status"] == "pending_review"
    material = source["source_refs"][0]["material_id"]
    mistake = c.post(
        f"{prefix}/mistakes/capture", json={"material_id": material, "original_answer": "5"}
    ).json()
    original_url = f"{prefix}/mistakes/{mistake['id']}/review-original"
    queue = f"{prefix}/assessment/review-queue"
    assert c.get(queue, headers=teacher_auth).status_code == 403
    assert c.get(queue).status_code == 403
    assert c.get(original_url, headers=teacher_auth).status_code == 403
    for permission in ("content:write", "assessment:review"):
        result = admin("grant", course, reviewer, permission)
        assert result.returncode == 0, result.stderr
    assert len(json.loads(admin("list", course).stdout)) == 2
    original = c.get(original_url, headers=teacher_auth)
    assert original.status_code == 200
    assert "算术平均数" in original.content.decode("utf-8")
    assert c.get(queue, headers=teacher_auth).json()["items"][0]["id"] == attempt["id"]
    assert (
        c.get(f"{prefix}/mistakes/review-queue", headers=teacher_auth).json()["items"][0]["id"]
        == mistake["id"]
    )
    # A separate course membership is not itself a grant.
    other = c.post("/api/v1/courses", json={"title": "另一课程"}).json()["course_id"]
    assert c.post(f"/api/v1/courses/{other}/members", json={"user_id": reviewer}).status_code == 200
    assert c.get(f"/api/v1/courses/{other}/assessment/review-queue", headers=teacher_auth).status_code == 403
    assert admin("grant", other, reviewer, "content:write").returncode == 0
    assert (
        c.get(
            f"/api/v1/courses/{other}/mistakes/{mistake['id']}/review-original", headers=teacher_auth
        ).status_code
        == 404
    )
    # Even an administrator explicitly granting the student a role cannot enable self-review.
    for permission in ("content:write", "assessment:review"):
        assert admin("grant", course, student, permission).returncode == 0
    assert c.get(original_url).status_code == 403
    assert c.get(queue).json()["items"] == []
    grade_url = f"{prefix}/attempts/{attempt['id']}/grade"
    payload = {"score": 1, "rationale": "推导表达完整，满足评分依据。"}
    assert c.post(grade_url, json=payload).status_code == 403
    confirm_url = f"{prefix}/mistakes/{mistake['id']}/confirm"
    draft = {
        "question": {
            "kind": "numeric",
            "prompt": "计算均值",
            "answer": "4",
            "explanation": "计算得到四。",
            "concept_ids": source["concept_ids"],
            "source_refs": source["source_refs"],
        }
    }
    assert c.post(confirm_url, json=draft).status_code == 403
    confirmed = c.post(confirm_url, json=draft, headers=teacher_auth)
    assert confirmed.status_code == 200
    confirmed_question = confirmed.json()["question_id"]
    sid = c.post(f"{prefix}/questions/{confirmed_question}/sessions").json()["id"]
    confirmed_attempt = c.post(
        f"{prefix}/attempts",
        headers={"Idempotency-Key": "teacher-confirmed"},
        json={"question_id": confirmed_question, "practice_session_id": sid, "answer": "4"},
    ).json()
    assert confirmed_attempt["score"] == 1 and confirmed_attempt["evidence_weight"] == 1
    grade = c.post(grade_url, json=payload, headers=teacher_auth)
    assert grade.status_code == 200, grade.text
    assert grade.json()["reviewed_by"] == reviewer
    assert admin("revoke", course, reviewer, "assessment:review").returncode == 0
    assert c.get(queue, headers=teacher_auth).status_code == 403
    # Removing membership removes every grant, so re-adding does not restore privileges.
    assert c.delete(f"/api/v1/courses/{course}/members/{reviewer}").status_code == 200
    assert c.post(f"/api/v1/courses/{course}/members", json={"user_id": reviewer}).status_code == 200
    assert c.get(f"{prefix}/mistakes/review-queue", headers=teacher_auth).status_code == 403
    with core.db() as db:
        assert db.execute("SELECT count(*) FROM review_permission_audit").fetchone()[0] >= 5


def test_authored_questions_and_author_key_do_not_create_self_evidence(integrated):
    c, course, source, _ = integrated
    student = core.current_user(c.headers["Authorization"])
    assert admin("grant", course, student, "content:write").returncode == 0
    prefix = f"/api/v1/courses/{course}"
    q = c.post(
        f"{prefix}/questions",
        json={
            "kind": "numeric",
            "prompt": "自拟一题",
            "answer": "12",
            "explanation": "自拟答案。",
            "concept_ids": source["concept_ids"],
            "source_refs": source["source_refs"],
        },
    )
    assert q.status_code == 201, q.text
    qid = q.json()["id"]
    from datetime import datetime, timedelta, timezone

    today = datetime.now(timezone(timedelta(hours=8))).date().isoformat()
    task = c.post(
        f"{prefix}/planner/tasks",
        json={
            "type": "practice",
            "target_id": qid,
            "title": "自拟题",
            "planned_date": today,
            "estimated_minutes": 10,
        },
    ).json()
    sid = c.post(f"{prefix}/questions/{qid}/sessions").json()["id"]
    before = c.get(f"{prefix}/mastery").json()
    result = c.post(
        f"{prefix}/attempts",
        headers={"Idempotency-Key": "authored-answer"},
        json={
            "question_id": qid,
            "practice_session_id": sid,
            "answer": "12",
            "source_task_id": task["task_id"],
        },
    ).json()
    assert result["score"] == 1 and result["evidence_weight"] == 0
    assert result["evidence_exclusion_reason"] == "self_authored_question"
    assert c.get(f"{prefix}/mastery").json() == before
    assert c.post("/api/v1/rewards/consume-events", json={"course_id": course}).status_code == 200
    assert c.get("/api/v1/rewards/points").json()["balance"] == 0
    assert c.get(f"/api/v1/planner/tasks/{task['task_id']}").json()["status"] == "pending"
    # A teacher who accesses a generated answer key has viewed the solution; grading it is assisted.
    assert c.get(f"{prefix}/questions/{source['id']}/answer-key").status_code == 200
    sid = c.post(f"{prefix}/questions/{source['id']}/sessions").json()["id"]
    result = c.post(
        f"{prefix}/attempts",
        headers={"Idempotency-Key": "seen-key"},
        json={
            "question_id": source["id"],
            "practice_session_id": sid,
            "answer": source["answer"],
        },
    ).json()
    assert result["score"] == 1 and result["solution_viewed"] and result["evidence_weight"] == 0
