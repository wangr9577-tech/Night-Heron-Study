import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from .errors import require


def now():
    return datetime.now(timezone.utc).isoformat()


def uid(prefix):
    return prefix + "_" + uuid4().hex


def dumps(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


class Database:
    def __init__(self, root: Path):
        self.root = root
        root.mkdir(parents=True, exist_ok=True)
        self.path = root / "learning.sqlite3"
        self.migrate()

    def connect(self):
        c = sqlite3.connect(self.path, timeout=30)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA foreign_keys=ON")
        c.execute("PRAGMA busy_timeout=30000")
        return c

    def migrate(self):
        with self.connect() as c:
            c.execute("PRAGMA journal_mode=WAL")
            c.execute(
                "CREATE TABLE IF NOT EXISTS b_schema_migrations(version TEXT PRIMARY KEY, applied_at TEXT)"
            )
            for path in sorted((Path(__file__).parents[1] / "migrations").glob("*.sql")):
                if not c.execute(
                    "SELECT 1 FROM b_schema_migrations WHERE version=?", (path.stem,)
                ).fetchone():
                    # Migrations are static repository SQL, never user-provided text.
                    c.executescript("BEGIN IMMEDIATE;\n" + path.read_text(encoding="utf-8"))
                    c.execute("INSERT INTO b_schema_migrations VALUES(?,?)", (path.stem, now()))
                    c.commit()

    @contextmanager
    def transaction(self):
        c = self.connect()
        try:
            c.execute("BEGIN IMMEDIATE")
            yield c
            c.commit()
        except Exception:
            c.rollback()
            raise
        finally:
            c.close()

    def put(self, c, user, course, kind, entity, id=None):
        key = id or entity.get("id") or uid(kind)
        entity = dict(entity, id=key)
        c.execute(
            """INSERT INTO b_entities(id,user_id,course_id,kind,data,updated_at)
            VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data,updated_at=excluded.updated_at
            WHERE b_entities.user_id=excluded.user_id AND b_entities.course_id=excluded.course_id
                AND b_entities.kind=excluded.kind""",
            (key, user, course, kind, dumps(entity), now()),
        )
        return entity

    def get(self, c, user, course, kind, key):
        r = c.execute(
            "SELECT data FROM b_entities WHERE id=? AND user_id=? AND course_id=? AND kind=?",
            (key, user, course, kind),
        ).fetchone()
        require(r is not None, "NOT_FOUND", "对象不存在或无访问权限", 404)
        return json.loads(r[0])

    def list(self, c, user, course, kind):
        return [
            json.loads(r[0])
            for r in c.execute(
                "SELECT data FROM b_entities WHERE user_id=? AND course_id=? AND kind=? ORDER BY rowid",
                (user, course, kind),
            )
        ]

    def event(self, c, user, course, event_type, result, source_task_id=None, event_id=None):
        data = dict(
            event_id=event_id or uid("evt"),
            user_id=user,
            course_id=course,
            source_task_id=source_task_id,
            event_type=event_type,
            result=result,
            occurred_at=now(),
        )
        c.execute(
            "INSERT OR IGNORE INTO b_events(event_id,user_id,course_id,data) VALUES(?,?,?,?)",
            (data["event_id"], user, course, dumps(data)),
        )
        return data

    def bump(self, c, user, course):
        c.execute(
            """INSERT INTO b_versions VALUES(?,?,1) ON CONFLICT(user_id,course_id)
            DO UPDATE SET version=version+1""",
            (user, course),
        )
