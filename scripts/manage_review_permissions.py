"""Manage review grants from a trusted local administrator account, never HTTP.

The database path is deliberately mandatory; a typo must not create a new database.
"""

import argparse
import datetime as dt
import getpass
import json
import sqlite3
from pathlib import Path

PERMISSIONS = ("content:write", "assessment:review")


def main():
    parser = argparse.ArgumentParser(description="管理课程专属内容与判分审核授权")
    parser.add_argument("--database", type=Path, required=True, help="现有 A 端 SQLite 数据库完整路径")
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("grant", "revoke"):
        command = sub.add_parser(action)
        command.add_argument("--user", required=True, help="审核者 user_id")
        command.add_argument("--course", required=True, help="课程 course_id")
        command.add_argument("--permission", required=True, choices=PERMISSIONS)
    query = sub.add_parser("list")
    query.add_argument("--course", required=True)
    args = parser.parse_args()
    database = args.database.resolve(strict=True)
    if not database.is_file():
        parser.error("database 必须是已存在的数据库文件")
    con = sqlite3.connect(database, timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys=ON")
    try:
        if args.action == "list":
            rows = con.execute(
                "SELECT course_id,user_id,permission,granted_at FROM review_permissions "
                "WHERE course_id=? ORDER BY user_id,permission",
                (args.course,),
            ).fetchall()
            print(json.dumps([dict(row) for row in rows], ensure_ascii=False, indent=2))
            return
        con.execute("BEGIN IMMEDIATE")
        if args.action == "grant":
            member = con.execute(
                "SELECT c.data FROM courses c JOIN members m ON m.course_id=c.course_id "
                "WHERE m.user_id=? AND m.course_id=?",
                (args.user, args.course),
            ).fetchone()
            if not member or json.loads(member["data"]).get("archived"):
                raise ValueError("审核者必须是未归档课程的现有成员")
            changed = con.execute(
                "INSERT OR IGNORE INTO review_permissions VALUES (?,?,?,?)",
                (args.course, args.user, args.permission, dt.datetime.now(dt.timezone.utc).isoformat()),
            ).rowcount
        else:
            changed = con.execute(
                "DELETE FROM review_permissions WHERE course_id=? AND user_id=? AND permission=?",
                (args.course, args.user, args.permission),
            ).rowcount
        if changed:
            con.execute(
                "INSERT INTO review_permission_audit(course_id,user_id,permission,action,operator,occurred_at) "
                "VALUES (?,?,?,?,?,?)",
                (
                    args.course,
                    args.user,
                    args.permission,
                    args.action,
                    getpass.getuser(),
                    dt.datetime.now(dt.timezone.utc).isoformat(),
                ),
            )
        con.commit()
        print(json.dumps({"action": args.action, "changed": bool(changed)}, ensure_ascii=False))
    finally:
        con.close()


if __name__ == "__main__":
    main()
