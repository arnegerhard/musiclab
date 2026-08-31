"""Local web app: paste a URL, watch it work, mix the stems in the browser."""

from __future__ import annotations

import json
import os
import traceback
import uuid
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel

from . import jobs, match, pipeline
from .api_auth import current_user
from .api_auth import router as auth_router
from .config import DEFAULT_FORMAT, OUT_DIR

SERVICE_TYPE = "_stems._tcp.local."

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


class JobRequest(BaseModel):
    # Either a direct URL, or a playlist track we have to match first.
    url: str | None = None
    track: PlaylistTrack | None = None
    split_vocals: bool = True
    split_drums: bool = True
    audio_format: str = DEFAULT_FORMAT
    # Low-confidence matches stop and ask rather than separating the wrong song.
    require_confident: bool = True


class BatchRequest(BaseModel):
    tracks: list[PlaylistTrack]
    split_vocals: bool = True
    split_drums: bool = True
    audio_format: str = DEFAULT_FORMAT
    require_confident: bool = True


class ConfirmRequest(BaseModel):
    video_id: str


def _update(job_id: str, **fields):
    jobs.store.update(job_id, **fields)


def _append_log(job_id: str, message: str):
    jobs.store.append_log(job_id, message)


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
        _update(job_id, status="error", phase="Failed", error="no url or track given")
        return None

    _update(job_id, phase=f"Finding audio for {track.title}")
    candidates = match.search(track.title, track.artist, track.duration)
    if not candidates:
        _update(job_id, status="error", phase="Failed", error="no match found")
        return None

    best = candidates[0]
    _update(job_id, match=_candidate_json(best),
            candidates=[_candidate_json(c) for c in candidates[:5]])

    if request.require_confident and not best.confident:
        # Separating the wrong recording wastes ten minutes and sounds wrong,
        # so an uncertain match waits for a human instead.
        _update(job_id, status="needs_confirmation", phase="Confirm the match")
        _append_log(job_id, f'Unsure: "{best.title}" scored {best.score}')
        return None

    _append_log(job_id, f'Matched "{best.title}" ({best.channel})')
    return best.url


def _run_job(job_id: str, request: dict | JobRequest):
    """Entry point for a worker, which may be another process entirely, so the
    request arrives as plain data."""
    request = request if isinstance(request, JobRequest) else JobRequest(**request)
    _update(job_id, status="running", phase="Starting")
    url = _resolve(job_id, request)
    if url is None:
        return
    _run_separation(job_id, request, url)


def _run_separation(job_id: str, request: dict | JobRequest, url: str):
    request = request if isinstance(request, JobRequest) else JobRequest(**request)
    _update(job_id, status="running", phase="Downloading audio")

    def progress(event):
        kind = event.get("kind")
        if kind == "download_progress":
            _update(job_id, progress=round(event["fraction"], 3))
        elif kind == "download_done":
            _update(job_id, phase="Audio downloaded", title=event["title"], progress=0)
            _append_log(job_id, f'Downloaded "{event["title"]}"')
        elif kind == "model_load":
            _update(job_id, phase=f'Loading model {event["model"]}')
        elif kind == "stage_start":
            _update(
                job_id,
                phase=f'{event["title"]} ({event["index"] + 1}/{event["total"]})',
            )
        elif kind == "stage_done":
            _append_log(job_id, f'{event["stage"]}: {", ".join(event["stems"])}')
        elif kind == "stage_skipped":
            _append_log(job_id, f'Skipped {event["stage"]}: {event["reason"]}')
        elif kind == "stem_missing":
            _append_log(job_id, f'Warning: {event["file"]} went missing')
        elif kind == "analyse_start":
            _update(job_id, phase="Measuring levels")

    job = jobs.store.get(job_id) or {}
    matched = job.get("match")
    extra = {"matched_from": matched, "playlist_track": request.track.model_dump()} if request.track else None

    try:
        result = pipeline.run(
            url,
            out_dir=user_dir({"id": job["user_id"]}),
            split_vocals=request.split_vocals,
            split_drums=request.split_drums,
            audio_format=request.audio_format,
            progress=progress,
            extra=extra,
        )
        _update(
            job_id,
            status="done",
            phase="Done",
            slug=result.job_dir.name,
            manifest=result.manifest,
        )
    except Exception as exc:
        traceback.print_exc()
        _update(job_id, status="error", phase="Failed", error=str(exc))


def _enqueue(request: JobRequest, user: dict) -> str:
    job_id = uuid.uuid4().hex[:12]
    jobs.store.create(job_id, {
        "id": job_id,
        "user_id": user["id"],
        "status": "queued",
        "phase": "Queued",
        "progress": 0,
        "url": request.url,
        "title": request.track.title if request.track else None,
        "artist": request.track.artist if request.track else None,
        "log": [],
        "request": request.model_dump(),
    })
    jobs.runner.submit(_run_job, job_id, request.model_dump())
    return job_id


@app.post("/api/match")
def find_match(track: PlaylistTrack, user: dict = Depends(current_user)):
    """Preview what a playlist track would be matched to, without separating."""
    candidates = match.search(track.title, track.artist, track.duration)
    return {"candidates": [_candidate_json(c) for c in candidates[:5]]}


@app.post("/api/jobs")
def create_job(request: JobRequest, user: dict = Depends(current_user)):
    if not (request.url and request.url.strip()) and request.track is None:
        raise HTTPException(400, "give either a url or a track")
    return {"id": _enqueue(request, user)}


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
    jobs.store.update(job_id, match=chosen, status="queued", phase="Queued")

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
                split_drums=request.split_drums,
                audio_format=request.audio_format,
                require_confident=request.require_confident,
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
                    "stem_count": len(manifest.get("stems", [])),
                }
            )
    return entries


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


def _local_ip() -> str:
    """Best guess at this machine's LAN address, for the QR/manual fallback."""
    import socket

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # No packets are sent; this just picks the interface that would route out.
        sock.connect(("192.168.0.1", 1))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def _advertise(port: int):
    """Publish over Bonjour so the phone does not need a typed-in IP."""
    try:
        import socket

        from zeroconf import ServiceInfo, Zeroconf

        # gethostname() can come back as a full DHCP-suffixed name
        # ("Mac.hsd1.ca.comcast.net"); Bonjour wants the short label plus
        # ".local.", so anything after the first dot has to go.
        short = socket.gethostname().split(".")[0].replace(" ", "-") or "mac"
        address = _local_ip()
        info = ServiceInfo(
            SERVICE_TYPE,
            f"stems on {short}.{SERVICE_TYPE}",
            addresses=[socket.inet_aton(address)],
            port=port,
            properties={"version": "1"},
            server=f"{short}.local.",
        )
        zeroconf = Zeroconf()
        # A previous run killed before it could unregister still holds the
        # name for a while, so let zeroconf pick "… (2)" rather than refusing.
        zeroconf.register_service(info, allow_name_change=True)
        return zeroconf, info
    except Exception as exc:  # discovery is a convenience, never fatal
        print(f"(Bonjour advertising unavailable: {type(exc).__name__}: {exc})")
        return None, None


def serve(port: int = 8000, host: str = "0.0.0.0", bonjour: bool | None = None) -> int:
    """Serve on all interfaces by default: the iOS app connects over the LAN.

    Bonjour is a local-network convenience only. It cannot cross the internet,
    and a deployed instance has no LAN worth advertising on, so anywhere but
    this Mac it should be off: set STEMS_BONJOUR=0 or pass --no-bonjour.
    """
    import uvicorn

    if bonjour is None:
        bonjour = os.environ.get("STEMS_BONJOUR", "1").strip() not in ("0", "false", "no")

    zeroconf = info = None
    if bonjour:
        zeroconf, info = _advertise(port)

    address = _local_ip()
    print(f"stems -> http://127.0.0.1:{port}   (this Mac)")
    print(f"         http://{address}:{port}   (iPhone, same Wi-Fi)")
    if zeroconf:
        print("         advertised over Bonjour; the app should find it itself")
    else:
        print("         Bonjour off — clients need the address or the public hostname")
    from . import auth, db
    db.purge_expired()
    accounts = len(db.all_users())
    print(f"         accounts: {accounts}"
          f"{' (create one in the app)' if accounts == 0 else ''}")
    print(f"         reset email: {'configured' if auth.smtp_configured() else 'not configured (codes print here)'}")

    try:
        uvicorn.run(app, host=host, port=port, log_level="warning")
    finally:
        if zeroconf and info:
            zeroconf.unregister_service(info)
            zeroconf.close()
    return 0
