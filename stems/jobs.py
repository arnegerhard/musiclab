"""Where job state lives, and who runs the separation.

Locally both are in this process: a dict guarded by a lock, and a thread pool.
On Modal the web app and the GPU worker are different containers, so neither
can be. Both are therefore swappable, and `server.py` only ever talks to the
`store` and `runner` objects below.
"""

from __future__ import annotations

import threading
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable


class MemoryJobStore:
    """Job state held in this process. Correct whenever one process does
    everything, which is the case on the Mac."""

    def __init__(self):
        self._jobs: dict[str, dict] = {}
        self._batches: dict[str, dict] = {}
        self._lock = threading.Lock()

    def create(self, job_id: str, data: dict) -> None:
        with self._lock:
            self._jobs[job_id] = data

    def get(self, job_id: str) -> dict | None:
        with self._lock:
            job = self._jobs.get(job_id)
            return dict(job) if job else None

    def update(self, job_id: str, **fields) -> None:
        with self._lock:
            if job_id in self._jobs:
                self._jobs[job_id].update(fields)

    def append_log(self, job_id: str, message: str) -> None:
        with self._lock:
            if job_id in self._jobs:
                self._jobs[job_id].setdefault("log", []).append(message)

    def set_batch(self, batch_id: str, job_ids: list[str], user_id: str) -> None:
        with self._lock:
            self._batches[batch_id] = {"jobs": job_ids, "user_id": user_id}

    def get_batch(self, batch_id: str) -> dict | None:
        with self._lock:
            batch = self._batches.get(batch_id)
            return dict(batch) if batch else None


class LocalRunner:
    """Separation in a thread pool here. One at a time, because it saturates
    the machine."""

    def __init__(self):
        self._executor = ThreadPoolExecutor(max_workers=1)

    def submit(self, function: Callable, *args: Any) -> None:
        self._executor.submit(function, *args)


def _no_refresh() -> None:
    """Locally the worker and the web app share a filesystem, so there is
    nothing to refresh."""


# Replaced at import time by modal_app.py when running on Modal.
store: Any = MemoryJobStore()
runner: Any = LocalRunner()
refresh: Callable[[], None] = _no_refresh


def use(new_store: Any, new_runner: Any, new_refresh: Callable[[], None] | None = None) -> None:
    global store, runner, refresh
    store, runner = new_store, new_runner
    if new_refresh is not None:
        refresh = new_refresh
