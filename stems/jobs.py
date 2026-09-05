"""Where job state lives, and who runs the separation.

Locally both are in this process: a dict guarded by a lock, and a thread pool.
On Modal the web app and the GPU worker are different containers, so neither
can be. Both are therefore swappable, and `server.py` only ever talks to the
`store` and `runner` objects below.
"""

from __future__ import annotations

import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable


#: Statuses a job never leaves.
from .states import Stage

# Only a song that arrived is out of the queue. A failed one stays until the
# person who asked for it has seen why and swiped it away -- listing it as
# finished is how the one failure worth reporting, a downloader YouTube has
# outgrown, managed to be invisible: the job left the queue the instant it
# became the thing worth saying.
FINISHED = {Stage.done.value}


class MemoryJobStore:
    """Job state held in this process. Correct whenever one process does
    everything, which is the case on the Mac."""

    def __init__(self):
        self._jobs: dict[str, dict] = {}
        self._batches: dict[str, dict] = {}
        self._workers: dict[str, dict] = {}
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

    def remove(self, job_id: str) -> None:
        with self._lock:
            self._jobs.pop(job_id, None)

    def append_log(self, job_id: str, message: str) -> None:
        with self._lock:
            if job_id in self._jobs:
                self._jobs[job_id].setdefault("log", []).append(message)

    def register_worker(self, user_id: str, info: dict) -> str:
        # Keyed on the machine where one is known, so a Mac that renames
        # itself -- or calls itself "Mac" while its pairing calls it something
        # else -- stays one worker rather than becoming two.
        identity = info.get("machine") or info.get("name") or "mac"
        worker_id = info.get("worker_id") or f"{user_id[:6]}-{identity}"
        with self._lock:
            self._workers[worker_id] = {
                **info, "worker_id": worker_id, "user_id": user_id, "seen": time.time()
            }
        return worker_id

    def workers(self, user_id: str) -> list[dict]:
        """Only those heard from recently; a worker that stops calling is gone."""
        cutoff = time.time() - 60
        with self._lock:
            return [
                w for w in self._workers.values()
                if w["user_id"] == user_id and w["seen"] > cutoff
            ]

    def active(self, user_id: str) -> list[dict]:
        """Everything this user has asked for that has not finished."""
        with self._lock:
            return [
                job for job in self._jobs.values()
                if job.get("user_id") == user_id
                and job.get("status") not in FINISHED
            ]

    def awaiting_fetch(self, user_id: str) -> list[str]:
        """Jobs this user has parked for an agent, oldest first."""
        with self._lock:
            return [
                job_id for job_id, job in self._jobs.items()
                if job.get("status") == Stage.waiting_for_worker.value and job.get("user_id") == user_id
            ]

    def set_batch(self, batch_id: str, job_ids: list[str], user_id: str) -> None:
        with self._lock:
            self._batches[batch_id] = {"jobs": job_ids, "user_id": user_id}

    def get_batch(self, batch_id: str) -> dict | None:
        with self._lock:
            batch = self._batches.get(batch_id)
            return dict(batch) if batch else None


class LocalRunner:
    """Separation in a thread here, one at a time.

    Nothing in production reaches this any more: the server runs on Modal,
    which replaces the runner with one that spawns a GPU container. It stays
    as the default so the app can be imported and exercised in a test without
    Modal, and so `store` and `runner` are never None.
    """

    def __init__(self):
        self._executor = ThreadPoolExecutor(max_workers=1)

    def submit(self, function: Callable, *args: Any) -> None:
        self._executor.submit(function, *args)


def _no_refresh() -> None:
    """Locally the worker and the web app share a filesystem, so there is
    nothing to refresh, and nothing to publish either."""


# Replaced at import time by modal_app.py when running on Modal.
store: Any = MemoryJobStore()
runner: Any = LocalRunner()
refresh: Callable[[], None] = _no_refresh   # see what other containers wrote
publish: Callable[[], None] = _no_refresh   # let them see what we wrote


def use(
    new_store: Any,
    new_runner: Any,
    new_refresh: Callable[[], None] | None = None,
    new_publish: Callable[[], None] | None = None,
) -> None:
    global store, runner, refresh, publish
    store, runner = new_store, new_runner
    if new_refresh is not None:
        refresh = new_refresh
    if new_publish is not None:
        publish = new_publish
