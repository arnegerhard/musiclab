"""Run Musiclab on Modal: a CPU web app, and a GPU container per song.

Separation is the slow part and the only part that wants a GPU, so it runs in
its own container. The library has to live next to that container rather than
on the Mac -- a finished song is ~150 MB of stems, and shipping that home over
a domestic uplink would cost back everything the GPU won.

Deploy:

    modal token new            # once, opens a browser
    modal deploy modal_app.py

Then point the app at the printed https://…modal.run URL.
"""

from __future__ import annotations

import modal

APP_NAME = "musiclab"
# Big enough that the models never spill, and the fastest tier that is widely
# available. "L40S" or "A10G" cost less per song for a modest slowdown.
GPU = "A100-80GB"

app = modal.App(APP_NAME)

# The library and the accounts database. One volume, so a finished song and the
# row that owns it cannot drift apart.
data = modal.Volume.from_name(f"{APP_NAME}-data", create_if_missing=True)

# Job state, which the web container and the GPU container both touch.
job_state = modal.Dict.from_name(f"{APP_NAME}-jobs", create_if_missing=True)

DATA_DIR = "/data"
MODEL_DIR = "/models"

ENVIRONMENT = {
    "STEMS_OUT_DIR": f"{DATA_DIR}/out",
    "STEMS_MODEL_DIR": MODEL_DIR,
    # Bonjour cannot cross the internet and there is no LAN here to advertise on.
    "STEMS_BONJOUR": "0",
    "MUSICLAB_SQLITE_JOURNAL": "DELETE",
}


def _fetch_models() -> None:
    """Pull the model weights at build time.

    ~1.3 GB of checkpoints. Downloading them on first request instead would put
    a minute of cold start in front of every idle-scaled container, which on a
    job that itself takes about a minute is the difference between fast and
    pointless.
    """
    import logging
    import os

    os.makedirs(MODEL_DIR, exist_ok=True)
    from audio_separator.separator import Separator

    from stems import models
    from stems.config import ALL_STAGES

    separator = Separator(
        log_level=logging.ERROR, model_file_dir=MODEL_DIR, output_dir="/tmp"
    )
    for stage in ALL_STAGES:
        name = models.resolve(stage.preferred, stage.model_keywords)
        if name:
            print(f"fetching {name}", flush=True)
            separator.download_model_files(name)


image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("ffmpeg")
    .pip_install(
        "yt-dlp>=2025.1.15",
        "audio-separator[gpu]>=0.30.0",
        "audioread>=3.0",
        "fastapi>=0.115",
        "python-multipart>=0.0.20",
        "soundfile>=0.13",
        "numpy>=1.26",
        "pyjwt[crypto]>=2.8",
    )
    .env(ENVIRONMENT)
    .add_local_python_source("stems", copy=True)
    .run_function(_fetch_models)
)


class ModalJobStore:
    """Job state in a modal.Dict, so the web app and the worker see the same
    thing. Each job is only ever written by one worker, so read-modify-write
    without a lock is safe here."""

    def __init__(self, backing):
        self._d = backing

    def create(self, job_id: str, data: dict) -> None:
        self._d[f"job:{job_id}"] = data

    def get(self, job_id: str) -> dict | None:
        return self._d.get(f"job:{job_id}")

    def update(self, job_id: str, **fields) -> None:
        job = self._d.get(f"job:{job_id}")
        if job is not None:
            job.update(fields)
            self._d[f"job:{job_id}"] = job

    def append_log(self, job_id: str, message: str) -> None:
        job = self._d.get(f"job:{job_id}")
        if job is not None:
            job.setdefault("log", []).append(message)
            self._d[f"job:{job_id}"] = job

    def set_batch(self, batch_id: str, job_ids: list[str], user_id: str) -> None:
        self._d[f"batch:{batch_id}"] = {"jobs": job_ids, "user_id": user_id}

    def get_batch(self, batch_id: str) -> dict | None:
        return self._d.get(f"batch:{batch_id}")


class ModalRunner:
    """Hands the job to a GPU container. The callable cannot cross the wire, so
    the worker is told which entry point to run by name."""

    def submit(self, function, *args) -> None:
        worker.spawn(function.__name__, *args)


def _install_runtime() -> None:
    from stems import jobs

    jobs.use(ModalJobStore(job_state), ModalRunner(), data.reload)


@app.function(
    image=image,
    gpu=GPU,
    volumes={DATA_DIR: data},
    timeout=3600,
    # Every song gets its own container, so a playlist separates in parallel
    # instead of one at a time.
    max_containers=10,
)
def worker(entry: str, *args) -> None:
    from stems import server

    _install_runtime()
    try:
        getattr(server, entry)(*args)
    finally:
        # Make the finished stems visible to the container serving them.
        data.commit()


@app.function(
    image=image,
    volumes={DATA_DIR: data},
    timeout=600,
    # One container: it owns the SQLite file, and nothing else writes it.
    max_containers=1,
    scaledown_window=300,
)
@modal.asgi_app()
def web():
    from stems.server import app as fastapi_app

    _install_runtime()
    return fastapi_app


@app.local_entrypoint()
def create_account(email: str = "", password: str = ""):
    """`modal run modal_app.py --email you@example.com --password ...`"""
    if not email or not password:
        print("Pass --email and --password.")
        return
    print(make_account.remote(email, password))


@app.function(image=image, volumes={DATA_DIR: data})
def make_account(email: str, password: str) -> str:
    from stems import users

    try:
        user = users.create(email, password)
    except Exception as exc:
        return f"Could not create the account: {exc}"
    data.commit()
    return f"Created {user['email']} ({user['id']})"
