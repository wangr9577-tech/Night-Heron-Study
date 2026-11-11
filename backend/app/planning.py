"""A-owned calendar changes; completed evidence and pinned tasks are immutable here."""

import datetime as dt
import json

from .core import now


def replan_pending(con, course, user):
    zone = dt.timezone(dt.timedelta(hours=8))
    today = dt.datetime.now(zone).date()
    last = dt.date.fromisoformat(course["ddl"]) if course.get("ddl") else today + dt.timedelta(days=30)
    last = min(last, today + dt.timedelta(days=365))
    rows = con.execute("SELECT data FROM tasks WHERE user_id=?", (user,)).fetchall()
    tasks = [json.loads(r["data"]) for r in rows]
    movable = sorted(
        [
            t
            for t in tasks
            if t["course_id"] == course["course_id"] and t["status"] not in ("done", "cancelled", "pinned")
        ],
        key=lambda t: (t["planned_date"], t.get("planned_time_slot") or "", t["task_id"]),
    )
    moving = {t["task_id"] for t in movable}
    occupied = [t for t in tasks if t["task_id"] not in moving and t["status"] != "cancelled"]
    placed, unscheduled, warnings = [], [], []
    for t in tasks:
        if (
            t["course_id"] == course["course_id"]
            and t["status"] == "pinned"
            and course.get("ddl")
            and t["planned_date"] > course["ddl"]
        ):
            warnings.append({"task_id": t["task_id"], "reason": "固定任务超过新截止日期，已保留原时段"})
    for task in movable:
        day = today
        slot = None
        while day <= last and slot is None:
            for window in sorted(
                [s for s in course.get("available_slots", []) if s["weekday"] == day.isoweekday()],
                key=lambda s: s["start"],
            ):
                start = dt.datetime.combine(day, dt.time.fromisoformat(window["start"]))
                finish = dt.datetime.combine(day, dt.time.fromisoformat(window["end"]))
                duration = dt.timedelta(minutes=task["estimated_minutes"])
                while start + duration <= finish:
                    clashes = []
                    for other in occupied:
                        if (
                            other["planned_date"] != str(day)
                            or not other.get("planned_time_slot")
                            or other.get("unscheduled")
                        ):
                            continue
                        a = dt.datetime.combine(day, dt.time.fromisoformat(other["planned_time_slot"]))
                        b = a + dt.timedelta(minutes=other["estimated_minutes"])
                        if start < b and start + duration > a:
                            clashes.append(b)
                    if clashes:
                        start = max(clashes)
                        continue
                    slot = start.strftime("%H:%M")
                    break
                if slot is not None:
                    break
            if slot is None:
                day += dt.timedelta(days=1)
        if slot is None:
            task.update(unscheduled=True, planned_time_slot=None)
            unscheduled.append({"task_id": task["task_id"], "reason": "截止日期前可用时段不足"})
        else:
            before = task["planned_date"]
            task.update(planned_date=str(day), planned_time_slot=slot, unscheduled=False)
            task.setdefault("reschedule_history", []).append(
                {"from_date": before, "to_date": str(day), "reason": "课程 DDL 或时段修改", "at": now()}
            )
            occupied.append(task)
            placed.append(task["task_id"])
        con.execute(
            "UPDATE tasks SET data=? WHERE task_id=? AND user_id=?",
            (json.dumps(task, ensure_ascii=False), task["task_id"], user),
        )
    return dict(rescheduled=placed, unscheduled=unscheduled, warnings=warnings)
