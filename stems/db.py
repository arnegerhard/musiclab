"""User and session storage.

SQLite rather than JSON files, for one concrete reason: the separation worker
writes from a background thread while request handlers read and write on the
event loop. Hand-rolled JSON persistence would need its own locking and could
still tear a write. This is still a single file with no server to run.
"""

from __future__ import annotations

import os
import secrets
import sqlite3
import threading
import time
from pathlib import Path

from .config import OUT_DIR

# Deliberately overridable and, on Modal, on a *different* volume from the
# library: reloading a volume fails while any file on it is open, and SQLite
# holds the database open for the life of the process.
DB_PATH = Path(os.environ.get("MUSICLAB_DB", str(Path(OUT_DIR).parent / "musiclab.db")))


def _no_flush() -> None:
    """Locally the file is already durable the moment SQLite writes it."""


# Replaced on Modal, where a volume must be committed to persist.
flush: "callable" = _no_flush


def _commit() -> None:
    connect().commit()
    flush()

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id            TEXT PRIMARY KEY,
    email         TEXT UNIQUE,
    password_hash TEXT,              -- null for Apple-only accounts
    apple_sub     TEXT UNIQUE,       -- Apple's stable user identifier
    display_name  TEXT,
    created_at    REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY,     -- the token itself is never stored
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at REAL NOT NULL,
    expires_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS pair_codes (
    code_hash  TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at REAL NOT NULL,
    expires_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS reset_codes (
    code_hash  TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at REAL NOT NULL,
    attempts   INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);
CREATE INDEX IF NOT EXISTS resets_user ON reset_codes(user_id);
CREATE INDEX IF NOT EXISTS pairs_user ON pair_codes(user_id);
"""

_local = threading.local()


def connect() -> sqlite3.Connection:
    """One connection per thread; SQLite objects are not shareable across them."""
    connection = getattr(_local, "connection", None)
    if connection is None:
        DB_PATH.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(DB_PATH, timeout=10)
        connection.row_factory = sqlite3.Row
        # WAL lets the worker thread write while requests read. On a network
        # volume its -wal and -shm side files are unreliable, so deployments
        # there set MUSICLAB_SQLITE_JOURNAL=DELETE instead.
        journal = os.environ.get("MUSICLAB_SQLITE_JOURNAL", "WAL")
        connection.execute(f"PRAGMA journal_mode={journal}")
        connection.execute("PRAGMA foreign_keys=ON")
        connection.executescript(SCHEMA)
        _migrate(connection)
        _local.connection = connection
    return connection


def _migrate(connection: sqlite3.Connection) -> None:
    """Bring an existing database up to the current schema.

    CREATE TABLE IF NOT EXISTS cannot add a column to a table that already
    exists, and these went in after the first accounts did.
    """
    existing = {row[1] for row in connection.execute("PRAGMA table_info(sessions)")}
    added = False
    for column, declaration in (
        ("id", "TEXT"),
        # 'full' is a sign-in and may do anything; 'worker' may only claim
        # work and deliver it back.
        ("scope", "TEXT NOT NULL DEFAULT 'full'"),
        ("label", "TEXT"),
        ("last_seen", "REAL"),
        # Which physical machine a worker session belongs to, so the same Mac
        # pairing again replaces its own row instead of adding another.
        ("machine", "TEXT"),
    ):
        if column not in existing:
            connection.execute(f"ALTER TABLE sessions ADD COLUMN {column} {declaration}")
            added = True
    if added:
        connection.execute(
            "UPDATE sessions SET id = lower(hex(randomblob(8))) WHERE id IS NULL"
        )
        connection.commit()


def new_id() -> str:
    return secrets.token_hex(12)


# MARK: users

def create_user(
    email: str | None = None,
    password_hash: str | None = None,
    apple_sub: str | None = None,
    display_name: str | None = None,
) -> dict:
    user_id = new_id()
    connect().execute(
        "INSERT INTO users (id, email, password_hash, apple_sub, display_name, created_at)"
        " VALUES (?, ?, ?, ?, ?, ?)",
        (user_id, email, password_hash, apple_sub, display_name, time.time()),
    )
    _commit()
    return get_user(user_id)


def get_user(user_id: str) -> dict | None:
    row = connect().execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    return dict(row) if row else None


def user_by_email(email: str) -> dict | None:
    row = connect().execute(
        "SELECT * FROM users WHERE email = ? COLLATE NOCASE", (email,)
    ).fetchone()
    return dict(row) if row else None


def user_by_apple(apple_sub: str) -> dict | None:
    row = connect().execute(
        "SELECT * FROM users WHERE apple_sub = ?", (apple_sub,)
    ).fetchone()
    return dict(row) if row else None


def set_password(user_id: str, password_hash: str) -> None:
    connect().execute(
        "UPDATE users SET password_hash = ? WHERE id = ?", (password_hash, user_id)
    )
    _commit()


def attach_apple(user_id: str, apple_sub: str) -> None:
    """Link an Apple identity to an account that already exists by email."""
    connect().execute(
        "UPDATE users SET apple_sub = ? WHERE id = ?", (apple_sub, user_id)
    )
    _commit()


def all_users() -> list[dict]:
    rows = connect().execute("SELECT * FROM users ORDER BY created_at").fetchall()
    return [dict(r) for r in rows]


# MARK: sessions

def create_session(
    user_id: str,
    token_hash: str,
    lifetime_days: int = 365,
    scope: str = "full",
    label: str | None = None,
    machine: str | None = None,
) -> str:
    """Returns the session's public id, which is what revocation refers to.

    The token itself never leaves the caller, so the id is what a listing can
    safely show.
    """
    now = time.time()
    session_id = new_id()
    connect().execute(
        "INSERT INTO sessions"
        " (token_hash, user_id, created_at, expires_at, id, scope, label, machine)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (token_hash, user_id, now, now + lifetime_days * 86400,
         session_id, scope, label, machine),
    )
    _commit()
    return session_id


def session_user(token_hash: str) -> dict | None:
    """The user, plus how much the presented token is allowed to do."""
    row = connect().execute(
        "SELECT u.*, s.scope AS token_scope, s.id AS token_id"
        " FROM sessions s JOIN users u ON u.id = s.user_id"
        " WHERE s.token_hash = ? AND s.expires_at > ?",
        (token_hash, time.time()),
    ).fetchone()
    return dict(row) if row else None


# A worker polls every few seconds; recording every one of those would mean a
# volume flush every few seconds for a field nobody reads that often.
TOUCH_INTERVAL_SECONDS = 30.0


def touch_session(token_hash: str) -> None:
    """Record that a token was used, so a listing can say when a Mac last
    checked in.

    Written at most every TOUCH_INTERVAL_SECONDS, and always committed. An
    earlier version skipped the commit to save the write, which was worse than
    useless: sqlite opens a transaction for the UPDATE either way, so the
    connection sat on a write lock forever and every other writer -- sign-in
    included -- failed with "database is locked".
    """
    now = time.time()
    cursor = connect().execute(
        "UPDATE sessions SET last_seen = ?"
        " WHERE token_hash = ? AND (last_seen IS NULL OR last_seen < ?)",
        (now, token_hash, now - TOUCH_INTERVAL_SECONDS),
    )
    if cursor.rowcount:
        _commit()
    else:
        # Nothing changed, but the transaction is open regardless. Close it
        # without paying for a volume flush.
        connect().commit()


def sessions_with_scope(user_id: str, scope: str) -> list[dict]:
    rows = connect().execute(
        "SELECT id, label, created_at, expires_at, last_seen FROM sessions"
        " WHERE user_id = ? AND scope = ? AND expires_at > ?"
        " ORDER BY created_at DESC",
        (user_id, scope, time.time()),
    ).fetchall()
    return [dict(row) for row in rows]


def retire_machine(user_id: str, machine: str) -> int:
    """Drop any worker session this machine already holds.

    A Mac that signs out hands its credential back, but a sign-out with the
    server unreachable cannot, and neither can one that was wiped. Without
    this, the owner's list of Macs grows a duplicate every time.
    """
    cursor = connect().execute(
        "DELETE FROM sessions WHERE user_id = ? AND scope = 'worker' AND machine = ?",
        (user_id, machine),
    )
    _commit()
    return cursor.rowcount


def delete_session_by_id(user_id: str, session_id: str) -> bool:
    """Scoped to the owner, so one account cannot revoke another's machine."""
    cursor = connect().execute(
        "DELETE FROM sessions WHERE id = ? AND user_id = ?", (session_id, user_id)
    )
    _commit()
    return cursor.rowcount > 0


def create_pair_code(user_id: str, code_hash: str, ttl_seconds: float) -> None:
    now = time.time()
    connect().execute(
        "INSERT OR REPLACE INTO pair_codes (code_hash, user_id, created_at, expires_at)"
        " VALUES (?, ?, ?, ?)",
        (code_hash, user_id, now, now + ttl_seconds),
    )
    _commit()


def take_pair_code(code_hash: str) -> dict | None:
    """Read and delete in one go: a pairing code is good for one machine."""
    row = connect().execute(
        "SELECT * FROM pair_codes WHERE code_hash = ? AND expires_at > ?",
        (code_hash, time.time()),
    ).fetchone()
    if row is None:
        return None
    connect().execute("DELETE FROM pair_codes WHERE code_hash = ?", (code_hash,))
    _commit()
    return dict(row)


def delete_session(token_hash: str) -> None:
    connect().execute("DELETE FROM sessions WHERE token_hash = ?", (token_hash,))
    _commit()


def purge_expired() -> None:
    now = time.time()
    connect().execute("DELETE FROM sessions WHERE expires_at < ?", (now,))
    connect().execute("DELETE FROM reset_codes WHERE expires_at < ?", (now,))
    connect().execute("DELETE FROM pair_codes WHERE expires_at < ?", (now,))
    _commit()


# MARK: password reset

def store_reset(user_id: str, code_hash: str, minutes: int = 15) -> None:
    # One live code per account, so an old email cannot be replayed.
    connect().execute("DELETE FROM reset_codes WHERE user_id = ?", (user_id,))
    connect().execute(
        "INSERT INTO reset_codes (code_hash, user_id, expires_at) VALUES (?, ?, ?)",
        (code_hash, user_id, time.time() + minutes * 60),
    )
    _commit()


def consume_reset(code_hash: str) -> dict | None:
    row = connect().execute(
        "SELECT * FROM reset_codes WHERE code_hash = ? AND expires_at > ?",
        (code_hash, time.time()),
    ).fetchone()
    if row is None:
        return None
    connect().execute("DELETE FROM reset_codes WHERE code_hash = ?", (code_hash,))
    _commit()
    return get_user(row["user_id"])


def count_reset_attempts(user_id: str) -> int:
    row = connect().execute(
        "SELECT attempts FROM reset_codes WHERE user_id = ?", (user_id,)
    ).fetchone()
    return row["attempts"] if row else 0


def record_reset_attempt(user_id: str) -> None:
    connect().execute(
        "UPDATE reset_codes SET attempts = attempts + 1 WHERE user_id = ?", (user_id,)
    )
    _commit()
