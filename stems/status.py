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
from .states import Failure, Stage, WorkerState

STATUS_PATH = Path(os.environ.get("MUSICLAB_STATUS", STATE_DIR / "status.json"))


class Status:
    """The worker's current state. Every setter rewrites the file."""

    def __init__(self, path: Path = STATUS_PATH):
        self.path = path
        self._state: dict[str, Any] = {
            # `state` is what this machine is; `stage` is what the song it
            # holds is. Both are enum values, never prose -- readers switch on
            # them, and `phase` exists only so a human sees words.
            "state": WorkerState.starting.value,
            "stage": None,
            "phase": WorkerState.starting.label,
            "detail": "",
            "progress": None,
            "song": "",
            "worker": "",
            "server": "",
            "songs_done": 0,
            "failure": None,
            "error": "",
        }
        self.write()

    def set(self, **fields) -> None:
        self._state.update(fields)
        self.write()

    def snapshot(self) -> dict[str, Any]:
        """A copy of the current state, for anyone who needs to forward it."""
        return dict(self._state)

    def touch(self) -> None:
        """Re-stamp the file without changing what it says.

        A separation stage can run for many minutes without emitting an event,
        and a reader that has heard nothing has no way to tell "still working"
        from "died mid-song". This is the worker saying it is still here.
        """
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

    # Every setter below states a named state. Nothing writes a phase string
    # of its own: the words come from the enum, so the Mac panel, the server
    # and the phone all say the same thing about the same moment.

    def idle(self, songs_done: int | None = None) -> None:
        fields = {
            "state": WorkerState.idle.value, "stage": None,
            "phase": WorkerState.idle.label, "detail": "", "progress": None,
            "song": "", "failure": None, "error": "",
        }
        if songs_done is not None:
            fields["songs_done"] = songs_done
        self.set(**fields)

    def working(self, stage: Stage, detail: str = "",
                progress: float | None = None, song: str | None = None) -> None:
        fields = {
            "state": WorkerState.busy.value,
            "stage": stage.value,
            "phase": stage.label,
            "detail": detail,
            # A bar is only drawn where a fraction means something, so an
            # indeterminate stage must not leave a stale number behind it.
            "progress": progress if stage.determinate else None,
            "failure": None,
            "error": "",
        }
        if song is not None:
            fields["song"] = song
        self.set(**fields)

    def apply(self, visible: dict, song: str | None = None) -> None:
        """Show what the server said this moment is called.

        The worker no longer decides: it reports what happened and is told
        what that means, so the menu bar and the phone cannot describe the
        same moment differently.
        """
        stage = visible.get("stage") or None
        fields = {
            "state": WorkerState.busy.value,
            "stage": stage,
            "phase": visible.get("phase") or "",
            "detail": visible.get("detail") or "",
            "progress": visible.get("progress"),
            "failure": None,
            "error": "",
        }
        if song is not None:
            fields["song"] = song
        self.set(**fields)

    def downloading_models(self, done_bytes: int, total_bytes: int) -> None:
        self.set(
            state=WorkerState.downloading_models.value,
            stage=Stage.loading_models.value,
            phase=WorkerState.downloading_models.label,
            detail=f"{done_bytes / 1e9:.1f} of about {total_bytes / 1e9:.1f} GB",
            progress=min(1.0, done_bytes / total_bytes) if total_bytes else None,
        )

    def failed(self, message: str, failure: Failure | None = None) -> None:
        kind = failure or Failure.unknown
        self.set(
            state=WorkerState.failed.value, stage=Stage.failed.value,
            phase=kind.label, detail=kind.remedy, progress=None,
            failure=kind.value, error=message,
        )

    def stopped(self) -> None:
        self.set(
            state=WorkerState.offline.value, stage=None,
            phase=WorkerState.offline.label, detail="", progress=None,
        )
