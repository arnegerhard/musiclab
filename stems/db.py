"""User and session storage.

SQLite rather than JSON files, for one concrete reason: the separation worker
writes from a background thread while request handlers read and write on the
event loop. Hand-rolled JSON persistence would need its own locking and could
still tear a write. This is still a single file with no server to run.
"""

from __future__ import annotations

import secrets
import sqlite3
import threading
import time
from pathlib import Path

from .config import OUT_DIR

DB_PATH = Path(OUT_DIR).parent / "musiclab.db"

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

CREATE TABLE IF NOT EXISTS reset_codes (
    code_hash  TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at REAL NOT NULL,
    attempts   INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);
CREATE INDEX IF NOT EXISTS resets_user ON reset_codes(user_id);
"""

_local = threading.local()


def connect() -> sqlite3.Connection:
    """One connection per thread; SQLite objects are not shareable across them."""
    connection = getattr(_local, "connection", None)
    if connection is None:
        DB_PATH.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(DB_PATH, timeout=10)
        connection.row_factory = sqlite3.Row
        # WAL lets the worker thread write while requests read.
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA foreign_keys=ON")
        connection.executescript(SCHEMA)
        _local.connection = connection
    return connection


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
    connect().commit()
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
    connect().commit()


def attach_apple(user_id: str, apple_sub: str) -> None:
    """Link an Apple identity to an account that already exists by email."""
    connect().execute(
        "UPDATE users SET apple_sub = ? WHERE id = ?", (apple_sub, user_id)
    )
    connect().commit()


def all_users() -> list[dict]:
    rows = connect().execute("SELECT * FROM users ORDER BY created_at").fetchall()
    return [dict(r) for r in rows]


# MARK: sessions

def create_session(user_id: str, token_hash: str, lifetime_days: int = 365) -> None:
    now = time.time()
    connect().execute(
        "INSERT INTO sessions (token_hash, user_id, created_at, expires_at)"
        " VALUES (?, ?, ?, ?)",
        (token_hash, user_id, now, now + lifetime_days * 86400),
    )
    connect().commit()


def session_user(token_hash: str) -> dict | None:
    row = connect().execute(
        "SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id"
        " WHERE s.token_hash = ? AND s.expires_at > ?",
        (token_hash, time.time()),
    ).fetchone()
    return dict(row) if row else None


def delete_session(token_hash: str) -> None:
    connect().execute("DELETE FROM sessions WHERE token_hash = ?", (token_hash,))
    connect().commit()


def purge_expired() -> None:
    now = time.time()
    connect().execute("DELETE FROM sessions WHERE expires_at < ?", (now,))
    connect().execute("DELETE FROM reset_codes WHERE expires_at < ?", (now,))
    connect().commit()


# MARK: password reset

def store_reset(user_id: str, code_hash: str, minutes: int = 15) -> None:
    # One live code per account, so an old email cannot be replayed.
    connect().execute("DELETE FROM reset_codes WHERE user_id = ?", (user_id,))
    connect().execute(
        "INSERT INTO reset_codes (code_hash, user_id, expires_at) VALUES (?, ?, ?)",
        (code_hash, user_id, time.time() + minutes * 60),
    )
    connect().commit()


def consume_reset(code_hash: str) -> dict | None:
    row = connect().execute(
        "SELECT * FROM reset_codes WHERE code_hash = ? AND expires_at > ?",
        (code_hash, time.time()),
    ).fetchone()
    if row is None:
        return None
    connect().execute("DELETE FROM reset_codes WHERE code_hash = ?", (code_hash,))
    connect().commit()
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
    connect().commit()
