"""Local web app: paste a URL, watch it work, mix the stems in the browser."""

from __future__ import annotations

import json
import os
import shutil
import tarfile
import time
import traceback
import uuid
from pathlib import Path

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel

from . import db, jobs, match, pipeline
from .api_auth import current_user, worker_user
from .api_auth import router as auth_router
from .states import Failure, Stage, WorkerState, classify
from .config import DEFAULT_FORMAT, OUT_DIR


# YouTube answers a home or carrier address and challenges a datacenter one, so
# a deployed server cannot fetch for itself. With this set it parks the job and
# waits for an agent on a residential connection to hand the audio over.
# How many machines get to try one song before it is called failed. Three is
# enough to ride out a flaky network and few enough that a permanent problem
# surfaces in under a minute rather than never.
MAX_ATTEMPTS = 3

DELEGATE_FETCH = os.environ.get("STEMS_DELEGATE_FETCH", "0").strip() not in ("0", "", "false", "no")

app = FastAPI(title="musiclab")
app.include_router(auth_router)


def user_dir(user: dict) -> Path:
    """Each account gets its own tree, so one user's songs are not merely
    hidden from another but stored somewhere else entirely."""
    path = OUT_DIR / user["id"]
    path.mkdir(parents=True, exist_ok=True)
    return path

# Separation saturates the machine, so one job at a time; the rest queue.
# The request body and owner are needed again when a paused job is confirmed,
# so they ride along inside the stored job rather than in a second dict.


class PlaylistTrack(BaseModel):
    """A track chosen in a playlist, before we know where its audio lives."""

    title: str
    artist: str = ""
    duration: float | None = None
    source: str = ""       # "apple" | "spotify"
    source_id: str = ""


class UploadedTrack(BaseModel):
    """Audio the app fetched itself, with what it knows about it."""

    title: str = ""
    uploader: str = ""
    duration: float | None = None
    url: str = ""
    video_id: str = ""


class JobRequest(BaseModel):
    # A direct URL, a playlist track to match first, or audio already uploaded.
    url: str | None = None
    track: PlaylistTrack | None = None
    uploaded_path: str | None = None
    uploaded_meta: UploadedTrack | None = None
    split_vocals: bool = True
    audio_format: str = DEFAULT_FORMAT
    # Low-confidence matches stop and ask rather than separating the wrong song.
    require_confident: bool = True
    # "mac" -- a paired machine does the whole thing, free and unhurried.
    # "cloud" -- the deployment's GPU separates, which costs money and is
    # several times faster. A link still needs a Mac to fetch it either way,
    # because YouTube will not answer this server.
    destination: str = "mac"


class BatchRequest(BaseModel):
    tracks: list[PlaylistTrack]
    split_vocals: bool = True
    audio_format: str = DEFAULT_FORMAT
    require_confident: bool = True
    # Where the separating happens, the same choice a single job carries.
    destination: str = "mac"


class ConfirmRequest(BaseModel):
    video_id: str


def _update(job_id: str, **fields):
    jobs.store.update(job_id, **fields)


def _stage(
    job_id: str,
    stage: Stage,
    *,
    detail: str | None = None,
    progress: float | None = None,
    failure: Failure | None = None,
    **fields,
) -> None:
    """Move a job to a named stage, and let the stage write its own words.

    Callers used to pass a status and a sentence -- "awaiting_fetch" with
    "Waiting for the fetch agent" -- which meant eighteen sentences existed,
    several described the same moment differently, and no interface could tell
    two of them apart. Now a caller names the stage and nothing else, so the
    words are the enum's and they are the same everywhere.
    """
    fields["status"] = stage.value
    fields["phase"] = failure.label if failure else stage.label
    if detail is not None:
        fields["detail"] = detail
    elif failure is not None:
        fields["detail"] = failure.remedy
    if not stage.determinate:
        # The stage decides, not the caller. A number here would be invented,
        # and leaving the previous stage's behind makes a bar that stalls --
        # both read as progress that is not happening.
        fields["progress"] = None
    elif progress is not None:
        fields["progress"] = progress
    if failure is not None:
        fields["failure"] = failure.value
    _update(job_id, **fields)


def _append_log(job_id: str, message: str):
    jobs.store.append_log(job_id, message)


def _leaf_count(stems: list) -> int:
    """How many stems can actually be placed in the room."""
    parents = {s.get("parent") for s in stems if s.get("parent")}
    return sum(1 for s in stems if s.get("name") not in parents)


def _public_job(job: dict) -> dict:
    """The stored request is internal plumbing; the client never needs it."""
    return {k: v for k, v in job.items() if k != "request"}


def _candidate_json(candidate: match.Candidate) -> dict:
    return {
        "video_id": candidate.video_id,
        "title": candidate.title,
        "channel": candidate.channel,
        "duration": candidate.duration,
        "score": candidate.score,
        "reasons": candidate.reasons,
        "url": candidate.url,
        "confident": candidate.confident,
    }


def _resolve(job_id: str, request: JobRequest) -> str | None:
    """Turn a playlist track into a YouTube URL, or park the job for review."""
    if request.url:
        return request.url
    track = request.track
    if track is None:
        _stage(job_id, Stage.failed, failure=Failure.unknown,
           error="no url or track given")
        return None

    _update(job_id, phase=f"Finding audio for {track.title}")
    candidates = match.search(track.title, track.artist, track.duration)
    if not candidates:
        _stage(job_id, Stage.failed, failure=Failure.no_match,
               error="no match found")
        return None

    best = candidates[0]
    _update(job_id, match=_candidate_json(best),
            candidates=[_candidate_json(c) for c in candidates[:5]])

    if request.require_confident and not best.confident:
        # Separating the wrong recording wastes ten minutes and sounds wrong,
        # so an uncertain match waits for a human instead.
        _stage(job_id, Stage.needs_confirmation)
        _append_log(job_id, f'Unsure: "{best.title}" scored {best.score}')
        return None

    _append_log(job_id, f'Matched "{best.title}" ({best.channel})')
    return best.url


def _run_job(job_id: str, request: dict | JobRequest):
    """Entry point for a worker, which may be another process entirely, so the
    request arrives as plain data."""
    request = request if isinstance(request, JobRequest) else JobRequest(**request)
    _stage(job_id, Stage.queued)
    if request.uploaded_path:
        # Nothing to find: the audio is already here.
        _run_separation(job_id, request, url="")
        return

    if DELEGATE_FETCH:
        # Both the search and the download have to happen somewhere YouTube
        # will answer, so the whole of it goes to the agent.
        _stage(job_id, Stage.waiting_for_worker)
        _append_log(job_id, "Queued for a fetch agent on a residential connection")
        return
    url = _resolve(job_id, request)
    if url is None:
        return
    _run_separation(job_id, request, url)


def _run_separation(job_id: str, request: dict | JobRequest, url: str):
    request = request if isinstance(request, JobRequest) else JobRequest(**request)
    _stage(job_id, Stage.fetching, progress=0.0)

    def progress(event):
        kind = event.get("kind")
        if kind == "download_progress":
            _stage(job_id, Stage.fetching, progress=round(event["fraction"], 3))
        elif kind == "download_done":
            _stage(job_id, Stage.decoding, title=event["title"])
            _append_log(job_id, f'Downloaded "{event["title"]}"')
        elif kind == "model_load":
            # On a cold GPU container this is most of the wait, and it used to
            # be a sentence with no state behind it -- the phone could show
            # the words but had no way to know a bar belonged here.
            done = event.get("index", 0)
            total = max(1, event.get("total", 1))
            _stage(
                job_id, Stage.loading_models, detail=event["model"],
                progress=round(done / total, 3),
            )
        elif kind == "stage_start":
            share = event["index"] / max(1, event["total"])
            _stage(
                job_id, Stage.separating,
                detail=f'{event["title"]} ({event["index"] + 1}/{event["total"]})',
                progress=round(share, 3),
            )
        elif kind == "stage_done":
            _append_log(job_id, f'{event["stage"]}: {", ".join(event["stems"])}')
        elif kind == "stage_skipped":
            _append_log(job_id, f'Skipped {event["stage"]}: {event["reason"]}')
        elif kind == "stem_missing":
            _append_log(job_id, f'Warning: {event["file"]} went missing')
        elif kind == "decode_start":
            _stage(job_id, Stage.decoding)
        elif kind == "analyse_start":
            _stage(job_id, Stage.packing, detail="Measuring levels")

    job = jobs.store.get(job_id) or {}
    matched = job.get("match")
    extra = {"matched_from": matched, "playlist_track": request.track.model_dump()} if request.track else None

    try:
        uploaded = Path(request.uploaded_path) if request.uploaded_path else None
        if uploaded is not None:
            # The upload was written by the web container, not this one.
            jobs.refresh()

        result = pipeline.run(
            url,
            out_dir=user_dir({"id": job["user_id"]}),
            uploaded=uploaded,
            metadata=request.uploaded_meta.model_dump() if request.uploaded_meta else None,
            split_vocals=request.split_vocals,
                audio_format=request.audio_format,
            progress=progress,
            extra=extra,
        )
        _stage(
            job_id, Stage.done, progress=1.0,
            slug=result.job_dir.name, manifest=result.manifest,
        )
    except Exception as exc:
        traceback.print_exc()
        _stage(job_id, Stage.failed, failure=classify(exc), error=str(exc))
    finally:
        # The upload has been decoded into the job folder; keeping the original
        # would store every song twice.
        if request.uploaded_path:
            Path(request.uploaded_path).unlink(missing_ok=True)


def _enqueue(request: JobRequest, user: dict) -> str:
    job_id = uuid.uuid4().hex[:12]
    jobs.store.create(job_id, {
        "id": job_id,
        "user_id": user["id"],
        "created_at": time.time(),
        "status": "queued",
        "phase": "Queued",
        "progress": 0,
        "url": request.url,
        "title": request.track.title if request.track else None,
        "artist": request.track.artist if request.track else None,
        "log": [],
        "request": request.model_dump(),
    })
    wants_cloud = request.destination == "cloud"

    # Audio that is already here needs nobody to fetch it, so the cloud can
    # take it straight away -- the one path that works with no Mac at all.
    if request.uploaded_path and wants_cloud:
        # A GPU container has to be started and has to pull the models onto
        # the card before it can do anything, which is a minute of apparent
        # silence. Say so, rather than showing "Queued" at a queue of one.
        _stage(
            job_id, Stage.loading_models,
            detail="Starting a GPU container",
        )
        jobs.runner.submit(_run_job, job_id, request.model_dump())
        return job_id

    if DELEGATE_FETCH or request.uploaded_path:
        # Both the search and the download have to happen somewhere YouTube
        # will answer. Decided here rather than in the worker: dispatching a
        # GPU container only to have it park the job would cost a cold start
        # and an accelerator to do nothing.
        _stage(
            job_id, Stage.waiting_for_worker,
            detail=None if not wants_cloud else "Then the cloud separates it",
        )
        jobs.store.append_log(
            job_id,
            "Queued for a Mac" if not wants_cloud
            else "Queued for a Mac to fetch, then the cloud to separate",
        )
        return job_id

    jobs.runner.submit(_run_job, job_id, request.model_dump())
    return job_id


@app.post("/api/match")
def find_match(track: PlaylistTrack, user: dict = Depends(current_user)):
    """Preview what a playlist track would be matched to, without separating."""
    candidates = match.search(track.title, track.artist, track.duration)
    return {"candidates": [_candidate_json(c) for c in candidates[:5]]}


class FetchFailure(BaseModel):
    error: str


class WorkerInfo(BaseModel):
    """What a worker says about itself when it checks in.

    The heartbeat used to carry a machine's specification and one boolean for
    whether it was busy, which is why the queue on the phone could list Macs
    but never say what any of them was doing. It now carries the same state
    the Mac shows in its own menu bar, so the two cannot disagree.
    """

    name: str = ""
    chip: str = ""
    cores: int = 0
    memory_gb: float = 0
    gpu: bool = False
    version: str = ""
    busy: bool = False
    state: str = WorkerState.idle.value
    stage: str = ""
    phase: str = ""
    detail: str = ""
    progress: float | None = None
    song: str = ""
    failure: str = ""


@app.post("/api/workers/register")
def register_worker(info: WorkerInfo, user: dict = Depends(worker_user)):
    """Announce a machine that can separate.

    A heartbeat, not a reservation: a worker that stops calling stops being
    offered work.

    The identity comes from the token rather than from anything the worker
    says about itself. A Mac calls itself by hostname -- "Mac" -- while the
    pairing it was adopted through knows a hardware UUID and the name its
    owner gave it, so the two could not be recognised as one machine and the
    same Mac appeared twice: once working, once offline.
    """
    described = info.model_dump()
    if user.get("token_machine"):
        described["machine"] = user["token_machine"]
    if user.get("token_label") and not described.get("name"):
        described["name"] = user["token_label"]
    worker_id = jobs.store.register_worker(user["id"], described)
    return {"worker_id": worker_id, "poll_seconds": 5}


@app.get("/api/workers")
def list_workers(user: dict = Depends(current_user)):
    """Every machine this account has, and what each is doing right now.

    Two sources have to be reconciled. A pairing is a Mac this account
    adopted, whether or not it is switched on; a heartbeat is a Mac that is
    running, whether or not it was ever paired. They do not agree on how to
    name a machine -- a pairing knows the hardware UUID it was adopted with, a
    heartbeat knows the hostname -- so a Mac that is both used to appear
    twice: once idle and once offline.
    """
    live: dict[str, dict] = {}
    for worker in jobs.store.workers(user["id"]):
        entry = dict(worker)
        entry.setdefault("state", WorkerState.idle.value)
        entry.setdefault("phase", WorkerState.idle.label)
        # A client decoding "stage" as an enum cannot make sense of "", and a
        # strict decoder throws away the whole list over one field.
        for field in ("stage", "failure"):
            if not entry.get(field):
                entry[field] = None
        entry["_key"] = entry.get("worker_id") or entry.get("name") or ""
        for key in (entry.get("machine"), entry.get("name"), entry.get("worker_id")):
            if key:
                live[key] = entry

    listed: list[dict] = []
    matched: set[str] = set()
    for pairing in db.sessions_with_scope(user["id"], "worker"):
        found = next(
            (live[key] for key in (pairing.get("machine"), pairing.get("label"))
             if key and key in live),
            None,
        )
        if found is None:
            # Adopted and silent, which is a fact worth showing: it is the
            # difference between nothing happening and nothing being able to.
            found = {
                "name": pairing.get("label") or "A Mac",
                "machine": pairing.get("machine") or "",
                "state": WorkerState.offline.value,
                "phase": WorkerState.offline.label,
                "stage": None, "failure": None, "detail": "", "song": "",
                "progress": None, "seen": pairing.get("last_seen"),
            }
        else:
            matched.add(found["_key"])
        entry = {k: v for k, v in found.items() if k != "_key"}
        entry["pairing_id"] = pairing.get("id")
        # The name its owner gave it at pairing beats the hostname it reports:
        # "Arne's MacBook Air" is what they called it, "Mac" is what it calls
        # itself, and only one of those is recognisable in a list.
        entry["name"] = pairing.get("label") or entry.get("name") or "A Mac"
        listed.append(entry)

    # A worker running against this account with no pairing behind it -- a
    # development build, say. Shown rather than dropped, and only once.
    for entry in {e["_key"]: e for e in live.values()}.values():
        if entry["_key"] not in matched:
            listed.append({k: v for k, v in entry.items() if k != "_key"})
    return listed


@app.get("/api/work/next")
def next_work(worker_id: str = "", user: dict = Depends(worker_user)):
    """Claim a whole job: fetch it, separate it, send the stems back.

    The same queue the fetch-only agent draws from. Whichever kind of helper
    claims first decides where the separation happens -- a worker keeps it on
    its own GPU, a fetch agent leaves it to the deployment's.
    """
    for job_id in jobs.store.awaiting_fetch(user["id"]):
        job = jobs.store.get(job_id)
        if job is None or job.get("status") != Stage.waiting_for_worker.value:
            continue
        # Asked for in the cloud: this Mac may fetch it, but the separating
        # belongs to the GPU. A fetch agent will take it instead.
        if job.get("request", {}).get("destination") == "cloud":
            continue
        # The worker will say which stage it is really in within seconds;
        # until its first report this is the honest answer.
        _stage(
            job_id, Stage.fetching, progress=0.0,
            worker_id=worker_id, claimed_at=time.time(),
        )
        request = job.get("request", {})
        return {
            "job_id": job_id,
            "url": request.get("url"),
            "track": request.get("track"),
            # Set when the audio was uploaded rather than linked: there is
            # nothing to download from the internet, only from here.
            "source_path": (
                f"/api/work/{job_id}/source" if request.get("uploaded_path") else None
            ),
            "metadata": request.get("uploaded_meta"),
            "audio_format": request.get("audio_format", DEFAULT_FORMAT),
            "split_vocals": request.get("split_vocals", True),
        }
    return {"job_id": None}


@app.get("/api/work/{job_id}/source")
def work_source(job_id: str, user: dict = Depends(worker_user)):
    """The audio for a job whose file was uploaded rather than linked."""
    job = jobs.store.get(job_id)
    if job is None or job.get("user_id") != user["id"]:
        raise HTTPException(404, "no such job")
    jobs.refresh()
    uploaded = job.get("request", {}).get("uploaded_path")
    if not uploaded or not Path(uploaded).exists():
        raise HTTPException(404, "no uploaded audio for this job")
    return FileResponse(uploaded)


@app.post("/api/work/{job_id}/result")
async def deliver_work(
    job_id: str,
    archive: UploadFile = File(...),
    slug: str = Form(...),
    user: dict = Depends(worker_user),
):
    """Unpack a finished song a worker separated on its own hardware."""
    job = jobs.store.get(job_id)
    if job is None or job.get("user_id") != user["id"]:
        raise HTTPException(404, "no such job")

    safe = Path(slug).name
    if not safe or safe.startswith("."):
        raise HTTPException(400, "bad slug")

    root = user_dir(user)
    staging = root / f".incoming-{uuid.uuid4().hex[:8]}"
    staging.mkdir(parents=True, exist_ok=True)
    bundle = staging / "result.tar"
    with bundle.open("wb") as handle:
        while chunk := await archive.read(1 << 20):
            handle.write(chunk)

    try:
        with tarfile.open(bundle) as tar:
            for member in tar.getmembers():
                # A worker is another machine; treat its archive as untrusted
                # and refuse anything that would write outside the job folder.
                target = (staging / member.name).resolve()
                if not target.is_relative_to(staging.resolve()) or member.issym() or member.islnk():
                    raise HTTPException(400, "the archive contains an unsafe path")
            tar.extractall(staging, filter="data")
    except tarfile.TarError as exc:
        shutil.rmtree(staging, ignore_errors=True)
        raise HTTPException(400, f"could not read the archive: {exc}") from exc
    finally:
        bundle.unlink(missing_ok=True)

    unpacked = staging / safe
    if not (unpacked / "manifest.json").exists():
        shutil.rmtree(staging, ignore_errors=True)
        raise HTTPException(400, "the archive has no manifest")

    destination = root / safe
    if destination.exists():
        shutil.rmtree(destination, ignore_errors=True)
    shutil.move(str(unpacked), str(destination))
    shutil.rmtree(staging, ignore_errors=True)
    jobs.publish()

    manifest = json.loads((destination / "manifest.json").read_text())
    _stage(
        job_id, Stage.done, progress=1.0, slug=safe, manifest=manifest,
        title=manifest.get("title"),
    )
    return {"ok": True}


class WorkProgress(BaseModel):
    """What the machine doing the separation is up to.

    `stage` is the whole point: the worker used to send a sentence, so the
    phone could print it and nothing more. A named stage can be reasoned
    about -- which bar to draw, whether a fraction means anything, whether
    this is the step that fails when a downloader goes stale.
    """
    stage: str = ""
    phase: str = ""
    detail: str = ""
    progress: float | None = None
    worker: str = ""


@app.post("/api/work/{job_id}/progress")
def work_progress(job_id: str, body: WorkProgress, user: dict = Depends(worker_user)):
    """The worker shows a phase and a bar locally; this is how the phone gets
    to show the same thing rather than an unmoving "Separating"."""
    job = jobs.store.get(job_id)
    if job is None or job.get("user_id") != user["id"]:
        raise HTTPException(404, "no such job")
    # An unrecognised stage is a worker newer or older than this server. Its
    # words are still worth showing, so keep the sentence and leave the stage
    # as it was rather than writing a value nothing can interpret.
    try:
        stage = Stage(body.stage)
    except ValueError:
        stage = None
    if stage is not None:
        _stage(
            job_id, stage, detail=body.detail, progress=body.progress,
            worker_name=body.worker,
        )
    else:
        _update(
            job_id,
            phase=body.phase or job.get("phase", ""),
            detail=body.detail,
            progress=body.progress,
            worker_name=body.worker,
        )
    jobs.publish()
    return {"ok": True}


@app.post("/api/work/{job_id}/failed")
def work_failed(job_id: str, body: FetchFailure, user: dict = Depends(worker_user)):
    """Hand the job back, or fail it, depending on why the worker stopped.

    Handing it back is right for a dropped connection: another Mac, or the
    same one in a minute, may manage. It is wrong for a video that has been
    taken down or a downloader YouTube has outgrown -- every worker reaches
    the same wall, so the song circles the queue for ever while the person who
    asked for it is told only that it is waiting for a Mac. Which is how the
    single failure worth reporting stayed invisible.
    """
    job = jobs.store.get(job_id)
    if job is None or job.get("user_id") != user["id"]:
        raise HTTPException(404, "no such job")
    failure = classify(body.error)

    # Handing a job back has to be able to stop. A failure nothing recognises
    # is retryable by default, which is right for a dropped connection and
    # ruinous for anything permanently wrong: one malformed link went round
    # this loop twenty-nine times, and would still be going.
    attempts = int(job.get("attempts") or 0) + 1
    if failure.retryable and attempts < MAX_ATTEMPTS:
        _stage(job_id, Stage.waiting_for_worker, worker_id=None,
               attempts=attempts)
        jobs.store.append_log(
            job_id,
            f"A worker gave up (attempt {attempts} of {MAX_ATTEMPTS}): {body.error}",
        )
    else:
        # A retryable failure that has run out of attempts is still a fetch
        # that did not finish, and saying so is more use than "unknown".
        if failure.retryable:
            failure = Failure.fetch_failed
        _stage(job_id, Stage.failed, failure=failure, error=body.error,
               worker_id=None, attempts=attempts)
        jobs.store.append_log(job_id, f"{failure.label}: {body.error}")
    return {"ok": True}


@app.get("/api/fetch/next")
def next_fetch(user: dict = Depends(worker_user)):
    """Claim the oldest job waiting to be fetched, for this user only."""
    for job_id in jobs.store.awaiting_fetch(user["id"]):
        job = jobs.store.get(job_id)
        if job is None or job.get("status") != Stage.waiting_for_worker.value:
            continue
        # A fetch agent only downloads; the GPU separates afterwards. That is
        # what "in the cloud" asked for, so leave the rest to a full worker.
        if job.get("request", {}).get("destination") != "cloud":
            continue
        _stage(job_id, Stage.fetching, progress=0.0)
        return {
            "job_id": job_id,
            "url": job.get("request", {}).get("url"),
            "track": job.get("request", {}).get("track"),
            "audio_format": job.get("request", {}).get("audio_format", DEFAULT_FORMAT),
        }
    return {"job_id": None}


@app.post("/api/fetch/{job_id}/failed")
def fetch_failed(job_id: str, body: FetchFailure, user: dict = Depends(worker_user)):
    job = jobs.store.get(job_id)
    if job is None or job.get("user_id") != user["id"]:
        raise HTTPException(404, "no such job")
    _stage(job_id, Stage.failed, failure=classify(body.error), error=body.error)
    return {"ok": True}


@app.post("/api/fetch/{job_id}")
async def deliver_fetch(
    job_id: str,
    audio: UploadFile = File(...),
    title: str = Form(""),
    uploader: str = Form(""),
    duration: float = Form(0),
    url: str = Form(""),
    video_id: str = Form(""),
    matched_from: str = Form(""),
    user: dict = Depends(worker_user),
):
    """The agent hands back the audio it fetched, and separation continues."""
    job = jobs.store.get(job_id)
    if job is None or job.get("user_id") != user["id"]:
        raise HTTPException(404, "no such job")

    destination = await _store_upload(audio, user)
    request = JobRequest(**job["request"])
    request.uploaded_path = str(destination)
    request.uploaded_meta = UploadedTrack(
        title=title, uploader=uploader, duration=duration or None,
        url=url, video_id=video_id,
    )
    updates: dict = {"request": request.model_dump(), "title": title or job.get("title")}
    if matched_from:
        try:
            updates["match"] = json.loads(matched_from)
        except json.JSONDecodeError:
            pass
    jobs.store.update(job_id, **updates)

    jobs.runner.submit(_run_separation, job_id, request.model_dump(), "")
    return {"ok": True}


async def _store_upload(audio: UploadFile, user: dict) -> Path:
    incoming = user_dir(user) / ".uploads"
    incoming.mkdir(parents=True, exist_ok=True)
    suffix = Path(audio.filename or "audio.m4a").suffix or ".m4a"
    destination = incoming / f"{uuid.uuid4().hex[:12]}{suffix}"
    size = 0
    with destination.open("wb") as handle:
        while chunk := await audio.read(1 << 20):
            size += len(chunk)
            handle.write(chunk)
    if size == 0:
        destination.unlink(missing_ok=True)
        raise HTTPException(400, "the upload was empty")
    # A worker in another container has to be able to read this.
    jobs.publish()
    return destination


@app.post("/api/upload")
async def upload(
    audio: UploadFile = File(...),
    title: str = Form(""),
    uploader: str = Form(""),
    duration: float = Form(0),
    url: str = Form(""),
    video_id: str = Form(""),
    audio_format: str = Form(DEFAULT_FORMAT),
    destination: str = Form("cloud"),
    user: dict = Depends(current_user),
):
    """Take audio the app downloaded and separate it.

    YouTube answers a phone on a home or carrier address and challenges a
    datacenter one, so the app does the fetching and the server never talks to
    YouTube at all.
    """
    # Named for what it is: "destination" is already the form field saying
    # where the separating should happen.
    stored = await _store_upload(audio, user)
    size = stored.stat().st_size
    request = JobRequest(
        uploaded_path=str(stored),
        uploaded_meta=UploadedTrack(
            title=title, uploader=uploader, duration=duration or None,
            url=url, video_id=video_id,
        ),
        audio_format=audio_format,
        destination=destination,
    )
    job_id = _enqueue(request, user)
    jobs.store.update(job_id, title=title or "Uploaded audio")
    return {"id": job_id, "bytes": size}


@app.post("/api/jobs")
def create_job(request: JobRequest, user: dict = Depends(current_user)):
    if not (request.url and request.url.strip()) and request.track is None:
        raise HTTPException(400, "give either a url or a track")
    return {"id": _enqueue(request, user)}


@app.get("/api/jobs")
def active_jobs(user: dict = Depends(current_user)):
    """Everything this user is waiting on, newest first.

    The phone shows this as a queue: a song can sit here for ten minutes
    while a Mac works through it, and until now the only way to watch was to
    stay on the screen you happened to submit from.
    """
    jobs.refresh()
    found = jobs.store.active(user["id"])
    found.sort(key=lambda job: job.get("created_at", 0), reverse=True)
    return [_public_job(job) for job in found]


@app.delete("/api/jobs/{job_id}")
def cancel_job(job_id: str, user: dict = Depends(current_user)):
    """Take a job out of the queue, and mean it.

    This used to mark the job cancelled rather than remove it, which worked
    only because a failed job counted as finished and so left the list on its
    own. Now that a failure stays visible until it has been read, marking it
    is not removing it: swiping one away left it exactly where it was, and
    nothing could ever be cleared.

    A worker already separating it will still finish and still deliver; the
    stems are kept. This is about the list.
    """
    job = jobs.store.get(job_id)
    if job is None or job.get("user_id") != user["id"]:
        raise HTTPException(404, "no such job")
    jobs.store.remove(job_id)
    jobs.publish()
    return {"ok": True}


@app.post("/api/jobs/{job_id}/confirm")
def confirm_job(job_id: str, choice: ConfirmRequest, user: dict = Depends(current_user)):
    """Accept one of the offered matches and let the job continue."""
    job = jobs.store.get(job_id)
    # Not "forbidden": another user's job should look like no job at all.
    if job is None or job.get("user_id") != user["id"]:
        raise HTTPException(404, "no such job")
    if job["status"] != "needs_confirmation":
        raise HTTPException(409, "this job is not waiting for confirmation")
    chosen = next(
        (c for c in job.get("candidates", []) if c["video_id"] == choice.video_id),
        None,
    )
    if chosen is None:
        raise HTTPException(400, "that match was not offered for this job")
    _stage(job_id, Stage.queued, match=chosen)

    jobs.runner.submit(_run_separation, job_id, job["request"], chosen["url"])
    return {"ok": True}


@app.post("/api/batch")
def create_batch(request: BatchRequest, user: dict = Depends(current_user)):
    """Queue a whole playlist selection. Jobs run one at a time."""
    if not request.tracks:
        raise HTTPException(400, "no tracks given")
    ids = [
        _enqueue(
            JobRequest(
                track=track,
                split_vocals=request.split_vocals,
                audio_format=request.audio_format,
                require_confident=request.require_confident,
                destination=request.destination,
            ),
            user,
        )
        for track in request.tracks
    ]
    batch_id = uuid.uuid4().hex[:12]
    jobs.store.set_batch(batch_id, ids, user["id"])
    return {"id": batch_id, "jobs": ids}


@app.get("/api/batch/{batch_id}")
def get_batch(batch_id: str, user: dict = Depends(current_user)):
    batch = jobs.store.get_batch(batch_id)
    if batch is None or batch.get("user_id") != user["id"]:
        raise HTTPException(404, "no such batch")
    found = [jobs.store.get(i) for i in batch["jobs"]]
    return {"id": batch_id, "jobs": [_public_job(j) for j in found if j]}


@app.get("/api/jobs/{job_id}")
def get_job(job_id: str, user: dict = Depends(current_user)):
    job = jobs.store.get(job_id)
    if job is None or job.get("user_id") != user["id"]:
        raise HTTPException(404, "no such job")
    return _public_job(job)


@app.get("/api/library")
def library(user: dict = Depends(current_user)):
    """This user's separated tracks, and only theirs."""
    # A worker may have finished a song in another container since the last
    # request; on a shared volume that is not visible until we look again.
    jobs.refresh()
    entries = []
    root = user_dir(user)
    if root.exists():
        for manifest_path in sorted(
            root.glob("*/manifest.json"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        ):
            try:
                manifest = json.loads(manifest_path.read_text())
            except (json.JSONDecodeError, OSError):
                continue
            entries.append(
                {
                    "slug": manifest_path.parent.name,
                    "title": manifest.get("title", manifest_path.parent.name),
                    "uploader": manifest.get("uploader", ""),
                    "duration": manifest.get("duration", 0),
                    # Leaves only. "vocals" and "drums" are in the manifest
                    # as the sum of their children, and counting them made
                    # the library claim fourteen while the mixer showed --
                    # and the phone fetched -- twelve.
                    "stem_count": _leaf_count(manifest.get("stems", [])),
                    # Checked on disk rather than trusted from the manifest:
                    # tracks separated before covers existed say nothing, and
                    # a backfill may have added one since.
                    "artwork": (
                        "cover.jpg"
                        if (manifest_path.parent / "cover.jpg").exists() else None
                    ),
                }
            )
    return entries


@app.delete("/api/auth/account")
def delete_account(user: dict = Depends(current_user)):
    """Delete this account and everything separated for it.

    Irreversible, and it takes the songs with it. An app that lets someone
    create an account has to let them remove one -- Apple requires it, and
    there was no way to do it at all.
    """
    jobs.refresh()
    directory = OUT_DIR / user["id"]
    if directory.is_dir():
        shutil.rmtree(directory, ignore_errors=True)
    # Sessions, reset codes and pairing codes cascade with the row.
    db.delete_user(user["id"])
    jobs.publish()
    return {"deleted": user.get("email")}


@app.delete("/api/library/{slug}")
def delete_track(slug: str, user: dict = Depends(current_user)):
    """Delete a separated track and every stem of it.

    Irreversible, and expensive to undo -- the song has to be separated again
    from scratch. Confined to this account's own tree, and the slug is checked
    to be a single path segment so a crafted one cannot climb out of it.
    """
    if "/" in slug or "\\" in slug or slug in ("", ".", ".."):
        raise HTTPException(400, "not a track name")

    jobs.refresh()
    directory = user_dir(user) / slug
    if not directory.is_dir():
        raise HTTPException(404, "no such track")
    # resolve() before comparing: a symlink inside the tree could otherwise
    # point the delete somewhere else entirely.
    root = user_dir(user).resolve()
    if not directory.resolve().is_relative_to(root):
        raise HTTPException(400, "not a track name")

    shutil.rmtree(directory, ignore_errors=True)
    jobs.publish()
    return {"deleted": slug}


@app.get("/api/library/{slug}")
def library_entry(slug: str, user: dict = Depends(current_user)):
    return json.loads((_job_dir(user, slug) / "manifest.json").read_text())


def _job_dir(user: dict, slug: str) -> Path:
    """Resolve a slug inside this user's tree, refusing anything outside it.

    Resolving first and then checking containment is what stops "../" and
    symlinks from reaching another user's songs.
    """
    root = user_dir(user).resolve()
    path = (root / slug).resolve()
    if not path.is_relative_to(root):
        raise HTTPException(404, "no such track")
    if not (path / "manifest.json").exists():
        # Might be a song that has only just finished elsewhere. Look again
        # before deciding it does not exist -- but only then, since refreshing
        # on every byte range would be wasteful.
        jobs.refresh()
        if not (path / "manifest.json").exists():
            raise HTTPException(404, "no such track")
    return path


@app.get("/api/health")
def health():
    """Lets the app confirm a host is a stems server, and its token is right.

    Sits behind the same token check as everything else, so a successful probe
    also proves the credentials work.
    """
    return {"service": "stems", "version": 2, "auth": "session"}


@app.get("/api/library/{slug}/scene")
def get_scene(slug: str, user: dict = Depends(current_user)):
    scene_path = _job_dir(user, slug) / "scene.json"
    if not scene_path.exists():
        return {}
    return json.loads(scene_path.read_text())


@app.put("/api/library/{slug}/scene")
def put_scene(slug: str, scene: dict, user: dict = Depends(current_user)):
    """Stored verbatim. The client owns the scene's shape, not the server."""
    scene_path = _job_dir(user, slug) / "scene.json"
    scene_path.write_text(json.dumps(scene, indent=2))
    return {"saved": True}


OUT_DIR.mkdir(parents=True, exist_ok=True)


@app.get("/files/{slug}/{relative:path}")
def stem_file(slug: str, relative: str, user: dict = Depends(current_user)):
    """Serve one file from one of this user's tracks.

    This used to be a StaticFiles mount over the whole output directory, which
    with accounts would have let any signed-in user read any other's songs by
    guessing a path. The URL carries no user id: the tree comes from the
    session, so it cannot be pointed somewhere else.
    """
    root = _job_dir(user, slug)
    path = (root / relative).resolve()
    if not path.is_relative_to(root) or not path.is_file():
        raise HTTPException(404, "no such file")
    # FileResponse answers Range requests, which audio seeking depends on.
    return FileResponse(path)
