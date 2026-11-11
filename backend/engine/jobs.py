import hashlib
import json
import logging
import threading
from datetime import datetime, timedelta, timezone

from .db import dumps, now, uid
from .errors import DomainError, require

log = logging.getLogger(__name__)


def public_job(row):
    data = dict(row)
    return {
        key: (
            json.loads(data[key])
            if key == "result_ref" and data[key]
            else bool(data[key])
            if key == "retryable"
            else data[key]
        )
        for key in (
            "job_id",
            "status",
            "progress",
            "result_ref",
            "error_code",
            "error_message",
            "retryable",
            "attempts",
            "created_at",
            "updated_at",
        )
    }


class JobQueue:
    """Durable SQLite queue. Claims are atomic; crashed workers recover after a 5-minute lease.

    Handlers are bounded (upload/page limits), pure file generation + one DB transaction.
    Result IDs derive from job IDs, so crash/retry does not duplicate business objects.
    """

    def __init__(self, engine):
        self.engine = engine
        self.stop_event = threading.Event()
        self.thread = None
        self.handlers = {}

    def enqueue(self, c, user, course, kind, payload, key=None):
        require(key is None or 1 <= len(key) <= 200, "INVALID_IDEMPOTENCY_KEY", "幂等键长度应为 1–200")
        digest = hashlib.sha256(dumps(payload).encode()).hexdigest()
        if key:
            existing = c.execute(
                """SELECT * FROM b_jobs WHERE user_id=? AND course_id=? AND kind=?
                AND idempotency_key=?""",
                (user, course, kind, key),
            ).fetchone()
            if existing:
                require(
                    existing["request_hash"] == digest, "IDEMPOTENCY_CONFLICT", "相同幂等键对应不同请求", 409
                )
                return public_job(existing)
        jid = uid("job")
        c.execute(
            """INSERT INTO b_jobs(job_id,user_id,course_id,kind,payload,status,created_at,updated_at,
            idempotency_key,request_hash) VALUES(?,?,?,?,?,'queued',?,?,?,?)""",
            (jid, user, course, kind, dumps(payload), now(), now(), key, digest),
        )
        return public_job(c.execute("SELECT * FROM b_jobs WHERE job_id=?", (jid,)).fetchone())

    def get(self, c, user, course, jid):
        row = c.execute(
            "SELECT * FROM b_jobs WHERE job_id=? AND user_id=? AND course_id=?", (jid, user, course)
        ).fetchone()
        require(row is not None, "NOT_FOUND", "任务不存在或无访问权限", 404)
        return public_job(row)

    def retry(self, c, user, course, jid):
        job = self.get(c, user, course, jid)
        require(job["status"] == "failed" and job["retryable"], "JOB_NOT_RETRYABLE", "任务当前不可重试", 409)
        require(job["attempts"] < 5, "RETRY_LIMIT", "已达到 5 次执行上限，请修复输入后新建任务", 409)
        c.execute(
            """UPDATE b_jobs SET status='queued',progress=0,error_code=NULL,error_message=NULL,
            retryable=0,updated_at=? WHERE job_id=?""",
            (now(), jid),
        )
        return self.get(c, user, course, jid)

    def run_one(self):
        db = self.engine.db
        with db.transaction() as c:
            c.execute(
                """UPDATE b_jobs SET status='queued',progress=0,lease_until=NULL WHERE status='running'
                AND lease_until<?""",
                (now(),),
            )
            row = c.execute(
                "SELECT * FROM b_jobs WHERE status='queued' ORDER BY created_at LIMIT 1"
            ).fetchone()
            if not row:
                return False
            row = dict(row)
            lease = (datetime.now(timezone.utc) + timedelta(minutes=5)).isoformat()
            c.execute(
                """UPDATE b_jobs SET status='running',progress=10,attempts=attempts+1,updated_at=?,
                lease_until=? WHERE job_id=?""",
                (now(), lease, row["job_id"]),
            )
        try:
            # The public permission gateway is checked again when a queued task actually executes.
            self.engine.access.require_course_access(row["user_id"], row["course_id"])
            handler = self.handlers[row["kind"]]
            payload = json.loads(row["payload"])
            result = handler(row, payload)
            with db.transaction() as c:
                c.execute(
                    """UPDATE b_jobs SET status='succeeded',progress=100,result_ref=?,error_code=NULL,
                    error_message=NULL,retryable=0,updated_at=?,lease_until=NULL WHERE job_id=?""",
                    (dumps(result), now(), row["job_id"]),
                )
        except Exception as exc:
            if isinstance(exc, DomainError):
                code, message, retryable = exc.code, exc.message, exc.retryable
            else:
                log.exception("Job %s failed", row["job_id"])
                code, message, retryable = "PROCESSING_FAILED", "处理失败，请检查服务日志后重试", True
            with db.transaction() as c:
                c.execute(
                    """UPDATE b_jobs SET status='failed',error_code=?,error_message=?,retryable=?,
                    updated_at=?,lease_until=NULL WHERE job_id=?""",
                    (code, message, int(retryable), now(), row["job_id"]),
                )
        return True

    def start(self):
        def loop():
            while not self.stop_event.is_set():
                try:
                    found = self.run_one()
                except Exception:
                    log.exception("Queue poll failed")
                    found = False
                if not found:
                    self.stop_event.wait(0.25)

        self.thread = threading.Thread(target=loop, name="zhuozhi-b-worker", daemon=True)
        self.thread.start()

    def close(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=30)
