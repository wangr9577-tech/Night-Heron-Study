import contextlib
import datetime as dt
import hashlib
import os
import secrets
import sqlite3
from pathlib import Path

from fastapi import Header, HTTPException

DB_PATH = Path(os.environ.get('ZHI_DB_PATH', Path(__file__).resolve().parent.parent / 'data' / 'zhi.db'))


@contextlib.contextmanager
def db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB_PATH, timeout=30)
    con.row_factory = sqlite3.Row
    con.execute('PRAGMA foreign_keys=ON')
    try:
        yield con
        con.commit()
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')


def new_id(prefix):
    return prefix + '_' + secrets.token_hex(10)


def password_hash(password, salt=None):
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), 260000).hex()
    return salt + '$' + digest


def current_user(authorization: str = Header(default='')):
    if not authorization.startswith('Bearer '):
        raise HTTPException(401, 'unauthorized')
    token = authorization[7:]
    with db() as con:
        row = con.execute('SELECT user_id FROM sessions WHERE token=?', (token,)).fetchone()
    if not row:
        raise HTTPException(401, 'unauthorized')
    return row['user_id']


def require_course(con, user_id, course_id):
    row = con.execute('SELECT role FROM members WHERE user_id=? AND course_id=?', (user_id, course_id)).fetchone()
    if not row:
        raise HTTPException(403, 'no_course_access')
    return row['role']


def init_core():
    with db() as con:
        con.executescript('''
        CREATE TABLE IF NOT EXISTS users (user_id TEXT PRIMARY KEY, username TEXT UNIQUE, password TEXT NOT NULL, data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sessions (token TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(user_id));
        CREATE TABLE IF NOT EXISTS courses (course_id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL REFERENCES users(user_id), data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS members (course_id TEXT NOT NULL REFERENCES courses(course_id), user_id TEXT NOT NULL REFERENCES users(user_id), role TEXT NOT NULL, PRIMARY KEY(course_id,user_id));
        CREATE TABLE IF NOT EXISTS tasks (task_id TEXT PRIMARY KEY, course_id TEXT NOT NULL REFERENCES courses(course_id), user_id TEXT NOT NULL REFERENCES users(user_id), data TEXT NOT NULL);
        ''')
