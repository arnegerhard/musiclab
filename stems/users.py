"""Account admin from the command line, and migration of pre-account songs."""

from __future__ import annotations

import shutil
from pathlib import Path

from . import auth, db
from .config import OUT_DIR


def create(email: str, password: str, display_name: str | None = None) -> dict:
    email = auth.normalise_email(email)
    if db.user_by_email(email):
        raise auth.AuthError("An account with that email already exists.")
    return db.create_user(
        email=email,
        password_hash=auth.hash_password(password),
        display_name=display_name,
    )


def listing() -> list[dict]:
    users = []
    for user in db.all_users():
        directory = OUT_DIR / user["id"]
        tracks = len(list(directory.glob("*/manifest.json"))) if directory.exists() else 0
        users.append({**user, "tracks": tracks})
    return users


def orphan_tracks() -> list[Path]:
    """Tracks sitting directly in out/, from before accounts existed."""
    if not OUT_DIR.exists():
        return []
    user_ids = {u["id"] for u in db.all_users()}
    return [
        path.parent
        for path in OUT_DIR.glob("*/manifest.json")
        if path.parent.name not in user_ids
    ]


def claim(email: str) -> int:
    """Move every pre-account track into one user's tree."""
    user = db.user_by_email(auth.normalise_email(email))
    if user is None:
        raise auth.AuthError(f"No account for {email}.")
    destination = OUT_DIR / user["id"]
    destination.mkdir(parents=True, exist_ok=True)

    moved = 0
    for track in orphan_tracks():
        target = destination / track.name
        if target.exists():
            continue
        shutil.move(str(track), str(target))
        moved += 1
    return moved
