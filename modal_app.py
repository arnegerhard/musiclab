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

# Two volumes, and they have to be two. Reloading a volume fails while any file
# on it is open, and SQLite holds the database open for the life of the
# process -- so the library the web app must reload cannot be the volume the
# database sits on.
data = modal.Volume.from_name(f"{APP_NAME}-data", create_if_missing=True)
database = modal.Volume.from_name(f"{APP_NAME}-db", create_if_missing=True)

# Job state, which the web container and the GPU container both touch.
job_state = modal.Dict.from_name(f"{APP_NAME}-jobs", create_if_missing=True)

DATA_DIR = "/data"
DB_DIR = "/db"
MODEL_DIR = "/models"

ENVIRONMENT = {
    "STEMS_OUT_DIR": f"{DATA_DIR}/out",
    "STEMS_MODEL_DIR": MODEL_DIR,
    # Bonjour cannot cross the internet and there is no LAN here to advertise on.
    "STEMS_BONJOUR": "0",
    "MUSICLAB_SQLITE_JOURNAL": "DELETE",
    "MUSICLAB_DB": f"{DB_DIR}/musiclab.db",
    # YouTube will not answer a datacenter, so fetching is delegated to an
    # agent running where it will.
    "STEMS_DELEGATE_FETCH": "1",
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
    .add_local_python_source("stems", copy=True)
    .run_function(_fetch_models)
    # After the download on purpose: image layers rebuild from the first one
    # that changed, and settings change far more often than 1.3 GB of weights.
    .env(ENVIRONMENT)
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

    def remove(self, job_id: str) -> None:
        self._d.pop(f"job:{job_id}", None)

    def append_log(self, job_id: str, message: str) -> None:
        job = self._d.get(f"job:{job_id}")
        if job is not None:
            job.setdefault("log", []).append(message)
            self._d[f"job:{job_id}"] = job

    def register_worker(self, user_id: str, info: dict) -> str:
        import time

        # Keyed on the machine where one is known: see jobs.MemoryJobStore.
        identity = info.get("machine") or info.get("name") or "mac"
        worker_id = info.get("worker_id") or f"{user_id[:6]}-{identity}"
        self._d[f"worker:{worker_id}"] = {
            **info, "worker_id": worker_id, "user_id": user_id, "seen": time.time()
        }
        return worker_id

    def prune(self, older_than: float) -> int:
        """Forget jobs that finished long ago.

        Nothing ever removed a finished job, so the Dict grew for the life of
        the deployment and every listing walked all of it.
        """
        stale = [
            key for key, job in self._d.items()
            if str(key).startswith("job:") and job
            and job.get("status") == "done"
            and float(job.get("updated_at") or 0) < older_than
        ]
        for key in stale:
            self._d.pop(key, None)
        return len(stale)

    def workers(self, user_id: str) -> list[dict]:
        import time

        cutoff = time.time() - 60
        found = []
        for key in self._d.keys():
            if not str(key).startswith("worker:"):
                continue
            worker = self._d.get(key)
            if worker and worker.get("user_id") == user_id and worker.get("seen", 0) > cutoff:
                found.append(worker)
        return found

    def active(self, user_id: str) -> list[dict]:
        # Imported here like the rest of this class: the module is not
        # available at import time in the Modal image build.
        from stems import jobs as job_module

        # items(), not keys() then get(): each get is a round trip to the
        # Dict, so listing a queue of two songs cost one trip per job ever
        # run. That was ten seconds of the eleven this endpoint took.
        found = []
        for key, job in self._d.items():
            if not str(key).startswith("job:") or not job:
                continue
            if (job.get("user_id") == user_id
                    and job.get("status") not in job_module.FINISHED):
                found.append(job)
        return found

    def awaiting_fetch(self, user_id: str) -> list[str]:
        from stems.states import Stage

        found = []
        for key, job in self._d.items():
            if not str(key).startswith("job:") or not job:
                continue
            if (job.get("status") == Stage.waiting_for_worker.value
                    and job.get("user_id") == user_id):
                found.append(str(key)[4:])
        return found

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
    from stems import db, jobs

    jobs.use(ModalJobStore(job_state), ModalRunner(), data.reload, data.commit)
    # A volume only persists what has been committed, so every database write
    # is followed by one.
    db.flush = database.commit


@app.function(
    image=image,
    gpu=GPU,
    volumes={DATA_DIR: data, DB_DIR: database},
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
    volumes={DATA_DIR: data, DB_DIR: database},
    timeout=600,
    # One container: it owns the SQLite file, and nothing else writes it.
    max_containers=1,
    scaledown_window=300,
    # The phone asks this container something the instant it launches, so a
    # cold start is a stall the person is watching. Snapshotting the process
    # after the imports turns ten to twenty seconds of Python and FastAPI
    # start-up into a restore of a page or two.
    enable_memory_snapshot=True,
    # Mail credentials live in a secret rather than in ENVIRONMENT, which is
    # baked into the image: an API key in an image layer is an API key that
    # travels with every copy of it. Reset codes print to the log until the
    # secret holds a real host, so the server is never locked out waiting.
    secrets=[modal.Secret.from_name("musiclab-smtp")],
)
@modal.asgi_app()
def web():
    from stems.server import app as fastapi_app

    _install_runtime()
    return fastapi_app


@app.function(
    image=image, gpu=GPU, volumes={DATA_DIR: data, DB_DIR: database}, timeout=3600
)
def benchmark(relative: str = "bench/source.flac") -> str:
    """Time the cascade on a file already on the volume, to compare the GPU
    against the Mac without YouTube in the way."""
    import logging
    import time
    from pathlib import Path

    import soundfile as sf
    import torch

    from stems.config import ALL_STAGES, MODEL_DIR as MODELS
    from stems.separate import Cascade

    source = Path(DATA_DIR) / relative
    seconds = sf.info(str(source)).duration
    lines = [f"gpu: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NONE'}",
             f"track: {seconds:.0f}s", ""]

    marks: dict[str, float] = {}

    def progress(event):
        if event.get("kind") == "stage_start":
            marks[event["stage"]] = time.time()
        elif event.get("kind") == "stage_done":
            stage = event["stage"]
            taken = time.time() - marks.get(stage, time.time())
            lines.append(f"  {stage:<7}{taken:7.1f}s   {taken / seconds:5.2f}x track")

    work = Path("/tmp/bench")
    started = time.time()
    Cascade(
        work_dir=work, stem_dir=work / "stems", model_dir=Path(MODELS),
        progress=progress, log_level=logging.ERROR,
    ).run(source, list(ALL_STAGES))
    total = time.time() - started
    lines.append(f"  {'TOTAL':<7}{total:7.1f}s   {total / seconds:5.2f}x track")
    return "\n".join(lines)


@app.function(image=image, timeout=120)
def _models_present() -> list[str]:
    """What weights the image actually carries, and how big they are."""
    import os
    from pathlib import Path

    found = []
    root = Path(MODEL_DIR)
    if not root.exists():
        return ["/models does not exist in the image"]
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.stat().st_size > 1_000_000:
            found.append(f"{path.stat().st_size / 1e6:8.0f} MB  {path.name}")
    return found or ["/models is empty"]


@app.function(image=image, gpu=GPU, timeout=600)
def _time_model_loads() -> list[str]:
    """How long the weights take to reach the GPU, per model.

    This is the number that decides whether a memory snapshot is worth the
    machinery: it is what a snapshot would remove from every job.
    """
    import logging
    import time

    from audio_separator.separator import Separator

    from stems import models as model_lookup
    from stems.config import ALL_STAGES

    out = []
    started = time.time()
    separator = Separator(
        log_level=logging.ERROR, model_file_dir=MODEL_DIR, output_dir="/tmp"
    )
    out.append(f"{time.time() - started:6.1f}s  constructing the separator")

    for stage in ALL_STAGES:
        name = model_lookup.resolve(stage.preferred, stage.model_keywords)
        if not name:
            continue
        mark = time.time()
        separator.load_model(name)
        out.append(f"{time.time() - mark:6.1f}s  loading {name}")
    out.append(f"{time.time() - started:6.1f}s  TOTAL before any audio is touched")
    return out


@app.local_entrypoint()
def loadtime():
    """`modal run modal_app.py::loadtime` -- what a snapshot would save."""
    for line in _time_model_loads.remote():
        print(" ", line)


@app.local_entrypoint()
def models():
    """`modal run modal_app.py::models` -- what the image ships with."""
    for line in _models_present.remote():
        print(" ", line)


@app.local_entrypoint()
def bench():
    """`modal run modal_app.py::bench`"""
    print(benchmark.remote())


@app.function(image=image, volumes={DATA_DIR: data}, timeout=600)
def _repair_slugs() -> list[str]:
    """Rename any track directory whose name is not ASCII.

    Such a name cannot be requested: the HTTP layer decodes path segments as
    ASCII and rejects the request before the app sees it. Tracks separated
    before slugify folded accents are stranded until they are renamed.
    """
    from pathlib import Path

    from stems.download import slugify

    renamed = []
    root = Path(f"{DATA_DIR}/out")
    for user_dir in root.glob("*"):
        if not user_dir.is_dir():
            continue
        for track in user_dir.glob("*"):
            if not track.is_dir() or track.name.isascii():
                continue
            # Keep the trailing id, which is already ASCII and is what makes
            # the name unique.
            head, _, tail = track.name.rpartition("-")
            fixed = f"{slugify(head)}-{tail}" if tail else slugify(track.name)
            target = track.parent / fixed
            if target.exists():
                continue
            track.rename(target)
            renamed.append(f"{track.name} -> {fixed}")
    data.commit()
    return renamed


@app.function(image=image, volumes={DATA_DIR: data}, timeout=900)
def _backfill_covers() -> list[str]:
    """Fetch a cover for every track separated before covers existed."""
    import json
    from pathlib import Path

    from stems.download import fetch_cover

    done = []
    for manifest_path in Path(f"{DATA_DIR}/out").glob("*/*/manifest.json"):
        folder = manifest_path.parent
        if (folder / "cover.jpg").exists():
            continue
        try:
            manifest = json.loads(manifest_path.read_text())
        except Exception:
            continue
        video_id = manifest.get("video_id")
        if not video_id:
            continue
        # The stored thumbnail url is long gone for old tracks, but YouTube
        # serves a predictable one per video id.
        for name in ("maxresdefault", "hqdefault"):
            url = f"https://i.ytimg.com/vi/{video_id}/{name}.jpg"
            if fetch_cover(url, folder / "cover.jpg"):
                done.append(f"{folder.name} <- {name}")
                break
    data.commit()
    return done


@app.function(image=image, volumes={DATA_DIR: data}, timeout=900)
def _trim_kits() -> list[str]:
    """Fold the drum kit back into one stem on tracks that were split.

    Separation no longer takes the kit apart, but tracks made before that
    still carry six pieces of it -- in their manifests, on disk, and so in
    every count the app shows. The pieces are identified by their parent
    rather than by name: whatever was split out of the drums goes.

    "leaf" and "children" are stored rather than worked out when read, so
    they are rebuilt from whatever survived. Without that a stem whose
    children have gone is still marked a parent, and the app plays leaves
    only -- which is how the drums vanished from the room after the first
    pass at this.
    """
    import json
    from pathlib import Path

    changed = []
    for manifest_path in Path(f"{DATA_DIR}/out").glob("*/*/manifest.json"):
        folder = manifest_path.parent
        try:
            manifest = json.loads(manifest_path.read_text())
        except Exception:
            continue

        before = json.dumps(manifest, sort_keys=True)

        pieces = [s for s in manifest.get("stems", []) if s.get("parent") == "drums"]
        for piece in pieces:
            for key in ("file", "spatial"):
                relative = piece.get(key)
                if relative:
                    (folder / relative).unlink(missing_ok=True)
        manifest["stems"] = [
            s for s in manifest.get("stems", []) if s.get("parent") != "drums"
        ]

        surviving = {s["name"] for s in manifest["stems"]}
        for stem in manifest["stems"]:
            stem["children"] = [c for c in stem.get("children", []) if c in surviving]
            stem["leaf"] = not stem["children"]

        manifest["stages"] = [
            st for st in manifest.get("stages", []) if st.get("key") != "drums"
        ]

        if json.dumps(manifest, sort_keys=True) == before:
            continue
        manifest_path.write_text(json.dumps(manifest, indent=2))
        note = f"dropped {len(pieces)} kit pieces" if pieces else "repaired leaf flags"
        changed.append(f"{folder.name}: {note}")

    data.commit()
    return changed


@app.local_entrypoint()
def trim():
    """Fold split drum kits back into one stem: `modal run modal_app.py::trim`"""
    found = _trim_kits.remote()
    for line in found:
        print(line)
    print(f"{len(found)} tracks tidied")


@app.local_entrypoint()
def covers():
    """Fetch covers for tracks that predate them: `modal run modal_app.py::covers`"""
    found = _backfill_covers.remote()
    for line in found:
        print(line)
    print(f"{len(found)} covers added")


@app.local_entrypoint()
def repair():
    """Fix track names that cannot be requested: `modal run modal_app.py::repair`"""
    for line in _repair_slugs.remote():
        print(line)
    print("done")


@app.local_entrypoint()
def account(email: str = "", password: str = ""):
    """Create an account: `MUSICLAB_PASSWORD=... modal run modal_app.py::account --email you@example.com`

    Deliberately over HTTP rather than by touching the database directly.
    SQLite lives on a volume, and a volume is snapshotted per container: a
    second container's writes are invisible to the web app, and committing
    from both would let one overwrite the other's whole file. The web
    container is the only writer, so account changes go through it.
    """
    import json
    import os
    import urllib.error
    import urllib.request

    password = password or os.environ.get("MUSICLAB_PASSWORD", "")
    if not email or not password:
        print("Pass --email, and either --password or MUSICLAB_PASSWORD.")
        return

    url = web.get_web_url().rstrip("/") + "/api/auth/signup"
    body = json.dumps({"email": email, "password": password}).encode()
    request = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            json.load(response)
        print(f"Created {email}")
    except urllib.error.HTTPError as exc:
        print(f"Could not create it: {json.load(exc).get('detail', exc.reason)}")
