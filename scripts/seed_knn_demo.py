"""Create an optional local KNN demo using the user's existing lecture PDF.

Usage: python scripts/seed_knn_demo.py [--source PATH]
The PDF and all derived records remain in ignored local data directories.
"""

import argparse
import hashlib
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
DEFAULT = Path(
    "D:/Study/Data Science & Machine Learning/Courses/Introduction to Data Science/Ch4 Classification/Notes/Ch4 K-Nearest Neighbors.pdf"
)


def run(source):
    from fastapi.testclient import TestClient

    from backend.app.main import app
    from backend.assessment.questions import create_question
    from backend.exams.generator import generate
    from backend.knowledge.service import create_concept
    from backend.materials.service import source_ref

    if not source.is_file():
        raise FileNotFoundError(f"找不到 KNN 讲义：{source}；请使用 --source 指定文件")
    with TestClient(app) as client:
        password = "Demo12345"
        login = client.post("/api/v1/auth/login", json={"username": "demo_knn", "password": password})
        if login.status_code == 401:
            login = client.post(
                "/api/v1/auth/register",
                json={"username": "demo_knn", "password": password, "nickname": "KNN 演示"},
            )
        login.raise_for_status()
        user = login.json()["user"]["user_id"]
        h = {"Authorization": "Bearer " + login.json()["access_token"]}
        courses = client.get("/api/v1/courses", headers=h).json()["items"]
        course = next(
            (x for x in courses if x["title"] == "数据科学导论 · KNN" and not x.get("archived")), None
        )
        if not course:
            course = client.post(
                "/api/v1/courses",
                headers=h,
                json={
                    "title": "数据科学导论 · KNN",
                    "subject": "数据科学",
                    "goal_text": "理解 KNN、分类指标与欧氏距离",
                    "ddl": (
                        datetime.now(timezone(timedelta(hours=8))).date() + timedelta(days=14)
                    ).isoformat(),
                    "available_slots": [
                        {"weekday": i, "start": "08:00", "end": "23:59"} for i in range(1, 8)
                    ],
                },
            )
            course.raise_for_status()
            course = course.json()
        cid = course["course_id"]
        with source.open("rb") as f:
            uploaded = client.post(
                "/api/v1/materials",
                headers=h,
                data={"course_id": cid},
                files={"file": (source.name, f, "application/pdf")},
            )
        uploaded.raise_for_status()
        material_id = uploaded.json()["material_id"]
        job = uploaded.json()["job_id"]
        deadline = time.monotonic() + 120
        while True:
            status = client.get("/api/v1/jobs/" + job, headers=h)
            status.raise_for_status()
            data = status.json()
            if data["status"] == "succeeded":
                break
            if data["status"] == "failed":
                raise RuntimeError(str(data))
            if time.monotonic() > deadline:
                raise TimeoutError("资料解析超时")
            time.sleep(0.2)
        engine = app.state.learning_engine
        engine.access.require_course_access(user, cid)
        specs = [
            ("分类准确率 Accuracy", 4, "Accuracy", "TP + TN"),
            ("召回率 Recall", 4, "Recall / sensitivity", "TP + FN"),
            ("精确率 Precision", 4, "Precision", "TP + FP"),
            ("欧氏距离 Euclidean distance", 6, "Euclidean distance", "distance"),
        ]
        question_ids = []
        with engine.db.transaction() as c:
            material = engine.db.get(c, user, cid, "material", material_id)
            for i, (title, page, term, formula) in enumerate(specs):
                chunk = next(
                    x
                    for x in material["chunks"]
                    if x["page"] == page and term in x["text"] and formula in x["text"]
                )
                ref = source_ref(material, chunk)
                concept = create_concept(
                    engine, c, user, cid, title, "来自 KNN 讲义的可验证学习知识点。", [ref]
                )
                if i == 0:
                    fixed_key = "demo_knn_fixed_" + hashlib.sha256(cid.encode()).hexdigest()[:20]
                    if not any(q["id"] == fixed_key for q in engine.db.list(c, user, cid, "question")):
                        create_question(
                            engine,
                            c,
                            user,
                            cid,
                            dict(
                                kind="numeric",
                                prompt="分类指标：TP=30，TN=45，FP=15，FN=10。准确率是多少？请用小数或分数作答。",
                                answer="0.75",
                                concept_ids=[concept["id"]],
                                source_refs=[ref],
                                explanation="准确率=(TP+TN)/(TP+TN+FP+FN)=75/100=0.75。",
                                initial_difficulty="easy",
                                rubric=["正确计算正确分类数量", "正确计算样本总数"],
                                options={},
                                accepted_answers=[],
                                hints=[
                                    "准确率的分子是预测正确的样本数。",
                                    "分母是全部样本数。",
                                    "将 TP+TN 除以全部样本数。",
                                ],
                            ),
                            key=fixed_key,
                            origin="local_study_demo",
                        )
                for ordinal in range(2):
                    key = "demo_knn_" + hashlib.sha256(f"{cid}:{i}:{ordinal}".encode()).hexdigest()[:24]
                    old = next((q for q in engine.db.list(c, user, cid, "question") if q["id"] == key), None)
                    if not old:
                        create_question(
                            engine,
                            c,
                            user,
                            cid,
                            generate(concept, "numeric", "easy", 31 + i, ordinal),
                            key=key,
                            origin="local_study_demo",
                        )
                    question_ids.append(key)
        today = datetime.now(timezone(timedelta(hours=8))).date().isoformat()
        from backend.app.core import db
        from backend.app.main import TaskInput, create_task, task_list

        with db() as c:
            existing = next(
                (
                    t
                    for t in task_list(c, cid, user)
                    if t["target_id"] == fixed_key and t["status"] != "cancelled"
                ),
                None,
            )
        if not existing:
            existing = create_task(
                cid,
                TaskInput(
                    type="practice",
                    target_id=fixed_key,
                    title="KNN 练习：计算分类准确率",
                    planned_date=today,
                    estimated_minutes=10,
                ),
                user,
            )
        return {
            "username": "demo_knn",
            "password": password,
            "course_id": cid,
            "material_id": material_id,
            "source": str(source),
            "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "question_count": len(question_ids) + 1,
            "fixed_task_id": existing["task_id"],
            "fixed_answer": "0.75",
        }


if __name__ == "__main__":
    import json

    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT)
    args = parser.parse_args()
    print(json.dumps(run(args.source), ensure_ascii=False, indent=2))
