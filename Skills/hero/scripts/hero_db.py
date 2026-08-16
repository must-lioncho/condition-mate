#!/usr/bin/env python3
"""Hero praise database manager.

Stores praise/recognition entries (nominator, nominee, skill+level,
detailed reason, next todo) in a SQLite database and renders them
in the team's standard praise format.

DB location, first match wins:
  1. $CM_HERO_DB                     — explicit override (same rule as HeroStore.dbPath)
  2. <workspace>/agent-mustcompany/storage/hero/heroes.db, when that path exists
  3. ~/.condition-mate/hero/heroes.db

The Condition Mate app reads this DB read-only for its Hero tab; this
script is its only writer.
"""

import argparse
import os
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

LEGACY_DB = (Path.home() / "Work/departtment_service/projects/agent-mustcompany"
             / "storage/hero/heroes.db")


def resolve_db() -> Path:
    env = os.environ.get("CM_HERO_DB", "").strip()
    if env:
        return Path(env).expanduser()
    if LEGACY_DB.exists():
        return LEGACY_DB
    return Path.home() / ".condition-mate" / "hero" / "heroes.db"


DB_PATH = resolve_db()

SCHEMA = """
CREATE TABLE IF NOT EXISTS heroes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL,
    nominator TEXT NOT NULL,
    nominee TEXT NOT NULL,
    nominee_korean TEXT,
    skill TEXT NOT NULL,
    level INTEGER NOT NULL,
    reason TEXT NOT NULL,
    next_todo TEXT NOT NULL,
    next_level_goal TEXT
);
"""


def get_conn():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute(SCHEMA)
    return conn


def format_entry(row) -> str:
    korean = f" ({row['nominee_korean']})" if row["nominee_korean"] else ""
    lines = [f"[{row['id']}] @{row['nominee']}{korean}"]
    body = (
        f"{row['skill']} (lv{row['level']}) / {row['reason']}"
        f" / next todo: {row['next_todo']}"
    )
    if row["next_level_goal"]:
        body += f" (next level: {row['next_level_goal']})"
    lines.append(body)
    return "\n".join(lines)


def cmd_add(args):
    conn = get_conn()
    created = datetime.now().strftime("%Y-%m-%d %H:%M")
    if args.id is not None:
        cur = conn.execute(
            "INSERT INTO heroes (id, created_at, nominator, nominee, nominee_korean,"
            " skill, level, reason, next_todo, next_level_goal)"
            " VALUES (?,?,?,?,?,?,?,?,?,?)",
            (args.id, created, args.nominator, args.nominee, args.nominee_korean,
             args.skill, args.level, args.reason, args.next_todo, args.next_level),
        )
    else:
        cur = conn.execute(
            "INSERT INTO heroes (created_at, nominator, nominee, nominee_korean,"
            " skill, level, reason, next_todo, next_level_goal)"
            " VALUES (?,?,?,?,?,?,?,?,?)",
            (created, args.nominator, args.nominee, args.nominee_korean,
             args.skill, args.level, args.reason, args.next_todo, args.next_level),
        )
    conn.commit()
    row = conn.execute("SELECT * FROM heroes WHERE id=?", (cur.lastrowid,)).fetchone()
    print(f"Saved entry #{row['id']} (nominator: {row['nominator']}, {row['created_at']})")
    print(f"db: {DB_PATH}")
    print()
    print(format_entry(row))


def cmd_list(args):
    conn = get_conn()
    query = "SELECT * FROM heroes"
    params = ()
    if args.nominee:
        query += " WHERE nominee LIKE ? OR nominee_korean LIKE ?"
        params = (f"%{args.nominee}%", f"%{args.nominee}%")
    query += " ORDER BY id"
    rows = conn.execute(query, params).fetchall()
    if not rows:
        print("No entries found.")
        return
    for row in rows:
        print(f"#{row['id']} | {row['created_at']} | {row['nominee']}"
              f" | {row['skill']} (lv{row['level']}) | by {row['nominator']}")


def cmd_show(args):
    conn = get_conn()
    row = conn.execute("SELECT * FROM heroes WHERE id=?", (args.id,)).fetchone()
    if not row:
        print(f"Entry #{args.id} not found.")
        sys.exit(1)
    print(format_entry(row))
    print()
    print(f"nominator: {row['nominator']} / recorded: {row['created_at']}")


def cmd_export(args):
    conn = get_conn()
    rows = conn.execute("SELECT * FROM heroes ORDER BY id").fetchall()
    if not rows:
        print("No entries to export.")
        return
    blocks = [format_entry(row) for row in rows]
    print("\n\n---\n\n".join(blocks))


def cmd_stats(args):
    conn = get_conn()
    rows = conn.execute(
        "SELECT nominee, COUNT(*) AS cnt, GROUP_CONCAT(skill || ' lv' || level, ', ')"
        " AS skills FROM heroes GROUP BY nominee ORDER BY cnt DESC"
    ).fetchall()
    if not rows:
        print("No entries yet.")
        return
    for row in rows:
        print(f"{row['nominee']}: {row['cnt']} nomination(s) — {row['skills']}")


def cmd_where(args):
    print(DB_PATH)


def main():
    parser = argparse.ArgumentParser(description="Hero praise DB")
    sub = parser.add_subparsers(dest="command", required=True)

    p_add = sub.add_parser("add", help="Add a praise entry")
    p_add.add_argument("--nominee", required=True)
    p_add.add_argument("--nominee-korean", default=None)
    p_add.add_argument("--nominator", required=True)
    p_add.add_argument("--skill", required=True)
    p_add.add_argument("--level", required=True, type=int)
    p_add.add_argument("--reason", required=True)
    p_add.add_argument("--next-todo", required=True)
    p_add.add_argument("--next-level", default=None,
                       help="Optional: the level after next (longer-term goal)")
    p_add.add_argument("--id", type=int, default=None,
                       help="Optional explicit entry number")
    p_add.set_defaults(func=cmd_add)

    p_list = sub.add_parser("list", help="List all entries")
    p_list.add_argument("--nominee", default=None)
    p_list.set_defaults(func=cmd_list)

    p_show = sub.add_parser("show", help="Show one entry in praise format")
    p_show.add_argument("id", type=int)
    p_show.set_defaults(func=cmd_show)

    p_export = sub.add_parser("export", help="Export all entries in praise format")
    p_export.set_defaults(func=cmd_export)

    p_stats = sub.add_parser("stats", help="Nomination counts per person")
    p_stats.set_defaults(func=cmd_stats)

    p_where = sub.add_parser("where", help="Print the resolved DB path")
    p_where.set_defaults(func=cmd_where)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
