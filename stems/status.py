"""What the worker is doing, written where a UI can read it.

A file rather than a socket: the UI and the worker start and stop
independently, and a file is still there to read when one of them was not
running. Writes are atomic, so a reader never catches half a line.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from .config import STATE_DIR

STATUS_PATH = Path(os.environ.get("MUSICLAB_STATUS", STATE_DIR / "status.json"))


class Status:
    """The worker's current state. Every setter rewrites the file."""

    def __init__(self, path: Path = STATUS_PATH):
        self.path = path
        self._state: dict[str, Any] = {
            "state": "starting",
            "phase": "",
            "detail": "",
            "progress": None,
            "song": "",
            "worker": "",
            "server": "",
            "songs_done": 0,
            "error": "",
        }
        self.write()

    def set(self, **fields) -> None:
        self._state.update(fields)
        self.write()

    def write(self) -> None:
        self._state["updated"] = time.time()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Write beside the target and rename: a reader either sees the old
        # file or the new one, never a partial write.
        temporary = self.path.with_suffix(".tmp")
        try:
            temporary.write_text(json.dumps(self._state, indent=2))
            os.replace(temporary, self.path)
        except OSError:
            pass                      # a UI that cannot read status is not fatal

    # Convenience states, so callers do not repeat the vocabulary.

    def idle(self, songs_done: int | None = None) -> None:
        fields = {"state": "idle", "phase": "Waiting for a song",
                  "detail": "", "progress": None, "song": "", "error": ""}
        if songs_done is not None:
            fields["songs_done"] = songs_done
        self.set(**fields)

    def working(self, phase: str, detail: str = "", progress: float | None = None,
                song: str | None = None) -> None:
        fields = {"state": "working", "phase": phase, "detail": detail,
                  "progress": progress}
        if song is not None:
            fields["song"] = song
        self.set(**fields)

    def downloading_models(self, done_bytes: int, total_bytes: int) -> None:
        self.set(
            state="downloading_models",
            phase="Getting the separation models",
            detail=f"{done_bytes / 1e9:.1f} of about {total_bytes / 1e9:.1f} GB",
            progress=min(1.0, done_bytes / total_bytes) if total_bytes else None,
        )

    def failed(self, message: str) -> None:
        self.set(state="error", phase="Something went wrong", detail=message,
                 progress=None, error=message)

    def stopped(self) -> None:
        self.set(state="stopped", phase="Not running", detail="", progress=None)
