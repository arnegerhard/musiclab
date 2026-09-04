"""Fetches audio for a server that cannot fetch for itself.

YouTube answers a home or carrier address and challenges a datacenter one, so
a deployed server parks its jobs and this polls for them from somewhere with a
residential connection. It dials out, so the machine running it needs no
inbound reachability at all.

    python -m stems.cli --agent https://your-app.modal.run
"""

from __future__ import annotations

import json
import mimetypes
import threading
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from . import download, match, models, pipeline
from .media import ensure_on_path
from .states import Failure, Stage, classify
from .status import Status


class Agent:
    def __init__(self, base_url: str, token: str, poll_seconds: float = 5.0):
        self.base = base_url.rstrip("/")
        self.token = token
        self.poll_seconds = poll_seconds
        self.worker_id = ""
        self.status = None
        self._song = ""
        self._job_id = ""
        self._done = 0

    # MARK: transport

    def _request(self, path: str, data: bytes | None = None, content_type: str | None = None):
        request = urllib.request.Request(f"{self.base}{path}", data=data)
        request.add_header("Authorization", f"Bearer {self.token}")
        if content_type:
            request.add_header("Content-Type", content_type)
        with urllib.request.urlopen(request, timeout=300) as response:
            body = response.read()
        return json.loads(body) if body else {}

    def _download(self, path: str, destination: Path) -> None:
        """Pull a file from the server, streamed, with this worker's token."""
        request = urllib.request.Request(f"{self.base}{path}")
        request.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(request, timeout=300) as response:
            with destination.open("wb") as handle:
                while chunk := response.read(1 << 20):
                    handle.write(chunk)

    def _post_json(self, path: str, payload: dict):
        return self._request(path, json.dumps(payload).encode(), "application/json")

    def _post_file(
        self, path: str, file: Path, fields: dict[str, str], field: str = "audio"
    ):
        """Multipart by hand, to keep the agent dependency-free."""
        boundary = f"musiclab.{uuid.uuid4().hex}"
        parts: list[bytes] = []
        for name, value in fields.items():
            parts.append(
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n"
                f"{value}\r\n".encode()
            )
        mime = mimetypes.guess_type(file.name)[0] or "application/octet-stream"
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; "
            f"filename=\"{file.name}\"\r\nContent-Type: {mime}\r\n\r\n".encode()
        )
        parts.append(file.read_bytes())
        parts.append(f"\r\n--{boundary}--\r\n".encode())
        return self._request(
            path, b"".join(parts), f"multipart/form-data; boundary={boundary}"
        )

    # MARK: work

    def claim(self) -> dict | None:
        try:
            job = self._request("/api/fetch/next")
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                raise RuntimeError("The agent's sign-in was rejected.") from exc
            return None
        except (urllib.error.URLError, TimeoutError):
            return None
        return job if job.get("job_id") else None

    def handle(self, job: dict, progress=print) -> None:
        job_id = job["job_id"]
        url = job.get("url")
        track = job.get("track")
        matched = None

        if not url and track:
            progress(f"  matching \"{track['title']}\"")
            best = match.best(
                track.get("title", ""), track.get("artist", ""), track.get("duration")
            )
            if best is None:
                self._post_json(f"/api/fetch/{job_id}/failed", {"error": "no match found"})
                return
            matched = {
                "video_id": best.video_id, "title": best.title, "channel": best.channel,
                "duration": best.duration, "score": best.score, "reasons": best.reasons,
                "url": best.url, "confident": best.confident,
            }
            url = best.url

        with tempfile.TemporaryDirectory() as staging:
            progress(f"  downloading {url}")
            source = download.fetch(url, Path(staging))
            # The server re-decodes anyway, so send the compact original
            # rather than the WAV it was expanded into.
            audio = next(
                (p for p in Path(staging).glob("source.*") if p.suffix != ".wav"),
                source.path,
            )
            progress(f"  uploading {audio.stat().st_size / 1e6:.1f} MB")
            self._post_file(
                f"/api/fetch/{job_id}",
                audio,
                {
                    "title": source.title, "uploader": source.uploader,
                    "duration": str(source.duration), "url": source.webpage_url,
                    "video_id": source.video_id,
                    "matched_from": json.dumps(matched) if matched else "",
                },
            )
        progress("  handed over")

    def run(self, once: bool = False, progress=print) -> None:
        progress(f"Fetch agent watching {self.base}")
        while True:
            job = self.claim()
            if job is None:
                if once:
                    progress("Nothing waiting.")
                    return
                time.sleep(self.poll_seconds)
                continue
            progress(f"job {job['job_id']}")
            try:
                self.handle(job, progress=progress)
            except Exception as exc:                       # keep the agent alive
                progress(f"  failed: {exc}")
                try:
                    self._post_json(f"/api/fetch/{job['job_id']}/failed", {"error": str(exc)})
                except Exception:
                    pass
            if once:
                return


class Worker(Agent):
    """Does the whole job on this machine and sends the stems back.

    Where the fetch agent only gets past YouTube and leaves the separation to
    the deployment's GPU, this keeps it here -- slower than an A100, but free,
    and several machines run several songs at once.

    Nothing is kept. The job folder is built in a temporary directory, packed,
    handed over, and deleted.
    """

    def describe(self) -> dict:
        import os
        import platform
        import subprocess

        def sysctl(key: str) -> str:
            # Absolute path: a packaged app launched from Finder gets a bare
            # PATH that does not include /usr/sbin.
            try:
                return subprocess.run(
                    ["/usr/sbin/sysctl", "-n", key],
                    capture_output=True, text=True, timeout=5,
                ).stdout.strip()
            except Exception:
                return ""

        memory = sysctl("hw.memsize")
        try:
            import torch

            gpu = torch.backends.mps.is_available()
        except Exception:
            gpu = False

        if not memory.isdigit():
            # Fall back to the standard library rather than reporting nothing.
            try:
                memory = str(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES"))
            except (ValueError, OSError):
                memory = "0"

        return {
            "name": platform.node().split(".")[0],
            "chip": sysctl("machdep.cpu.brand_string") or platform.machine(),
            "cores": int(sysctl("hw.ncpu") or 0) or (os.cpu_count() or 0),
            "memory_gb": round(int(memory) / 1e9, 1) if memory.isdigit() else 0,
            "gpu": gpu,
            "version": "1",
        }

    def register(self, busy: bool = False) -> str:
        """Check in, carrying whatever this Mac is doing at the moment.

        The heartbeat is the only thing the server hears from an idle worker,
        so it is also the only chance to say what state it is in. Sending the
        machine's own status here is what lets the phone's queue and the Mac's
        menu bar agree without a second channel.
        """
        state = self.status.snapshot() if self.status else {}
        reply = self._post_json("/api/workers/register", {
            **self.describe(),
            "busy": busy,
            "state": state.get("state") or "",
            "stage": state.get("stage") or "",
            "phase": state.get("phase") or "",
            "detail": state.get("detail") or "",
            "progress": state.get("progress"),
            "song": state.get("song") or "",
            "failure": state.get("failure") or "",
        })
        return reply.get("worker_id", "")

    def claim(self) -> dict | None:
        try:
            job = self._request(f"/api/work/next?worker_id={self.worker_id}")
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                raise RuntimeError("The worker's sign-in was rejected.") from exc
            return None
        except (urllib.error.URLError, TimeoutError):
            return None
        return job if job.get("job_id") else None

    def handle(self, job: dict, progress=print) -> None:
        import shutil
        import tarfile

        job_id = job["job_id"]
        url, track = job.get("url"), job.get("track")
        title = (track or {}).get("title", "") if track else ""
        self.status.working(Stage.fetching, detail="Finding the song",
                            song=title, progress=0.02)

        if not url and track:
            progress(f"  matching \"{track['title']}\"")
            best = match.best(
                track.get("title", ""), track.get("artist", ""), track.get("duration")
            )
            if best is None:
                self._post_json(f"/api/work/{job_id}/failed", {"error": "no match found"})
                return
            url = best.url

        with tempfile.TemporaryDirectory() as staging:
            out = Path(staging)

            # Audio that was uploaded rather than linked: there is nothing on
            # the internet to fetch, only the file the phone sent up.
            uploaded = None
            if job.get("source_path"):
                progress("  collecting the uploaded audio")
                self.status.working(Stage.fetching, detail="Collecting the audio",
                                    song=title, progress=0.04)
                uploaded = out / "source"
                self._download(job["source_path"], uploaded)

            progress("  separating locally")
            self.status.working(Stage.separating, song=title, progress=0.05)
            result = pipeline.run(
                url,
                out_dir=out,
                uploaded=uploaded,
                metadata=job.get("metadata"),
                split_vocals=job.get("split_vocals", True),
                audio_format=job.get("audio_format", "flac"),
                progress=lambda e: self._note(e, progress),
            )

            bundle = out / "result.tar"
            progress("  packing")
            self.status.working(Stage.packing, song=self._song, progress=0.9)
            with tarfile.open(bundle, "w") as tar:
                tar.add(result.job_dir, arcname=result.job_dir.name)
            size = bundle.stat().st_size / 1e6
            progress(f"  uploading {size:.0f} MB")
            self.status.working(
                Stage.uploading, detail=f"{size:.0f} MB",
                song=self._song, progress=0.95,
            )
            self._post_file(
                f"/api/work/{job_id}/result",
                bundle,
                {"slug": result.job_dir.name},
                field="archive",
            )
            # Nothing is kept: the temporary directory goes with this block.
            shutil.rmtree(result.job_dir, ignore_errors=True)
        progress("  handed over")

    def _report(self) -> None:
        """Forward the local status to the server.

        The Mac shows a phase and a bar; without this the phone that asked for
        the song sees only "Separating on a worker" for the whole ten minutes.
        Best effort -- a dropped progress ping must never fail a job.
        """
        if not self._job_id or self.status is None:
            return
        state = self.status.snapshot()
        try:
            self._post_json(
                f"/api/work/{self._job_id}/progress",
                {
                    "stage": state.get("stage") or "",
                    "phase": state.get("phase", ""),
                    "detail": state.get("detail", ""),
                    "progress": state.get("progress"),
                    "worker": state.get("worker", ""),
                },
            )
        except Exception:
            pass

    def _note(self, event: dict, progress) -> None:
        """Turn pipeline events into a named stage and a fraction.

        Every branch names a Stage rather than writing a sentence, so the Mac
        panel, the queue on the phone and the server all describe this moment
        with the same word. The fractions divide one bar across the whole
        song: fetching owns the first tenth, separating the middle, packing
        the rest.
        """
        kind = event.get("kind")
        if kind == "download_progress":
            self.status.working(
                Stage.fetching, song=self._song,
                progress=0.02 + 0.06 * float(event.get("fraction", 0)),
            )
        elif kind == "decode_start":
            # No fraction: ffmpeg reports none, and a bar that crawls on
            # invented numbers is worse than an honest spinner.
            self.status.working(Stage.decoding, song=self._song)
        elif kind == "download_done":
            self._song = event.get("title", self._song)
            progress(f'    got "{self._song}"')
        elif kind == "model_load":
            # Minutes on a cold Mac, and until now it read as a hang: the
            # pipeline has always emitted this and nothing listened.
            self.status.working(
                Stage.loading_models, detail=event.get("model", ""),
                song=self._song,
            )
        elif kind == "stage_start":
            progress(f"    {event['title']}")
            share = event.get("index", 0) / max(1, event.get("total", 1))
            self.status.working(
                Stage.separating, detail=event["title"], song=self._song,
                progress=0.10 + 0.70 * share,
            )
        elif kind == "encode_start":
            self.status.working(Stage.packing, song=self._song, progress=0.82)
        elif kind == "analyse_start":
            self.status.working(
                Stage.packing, detail="Measuring levels",
                song=self._song, progress=0.88,
            )
        self._report()

    def run(self, once: bool = False, progress=print) -> None:
        ensure_on_path()
        self.status = Status()
        self._song = ""
        self._job_id = ""
        self._done = 0
        ensure_on_path()

        self.worker_id = self.register()
        info = self.describe()
        self.status.set(worker=info["name"], server=self.base)
        progress(f"Worker {self.worker_id} watching {self.base}")
        progress(f"  {info['chip']}, {info['cores']} cores, GPU: {info['gpu']}")

        # Up front, so a fresh worker says what it is waiting for rather than
        # appearing to hang for several minutes on its first song.
        from .config import MODEL_DIR

        if models.missing(MODEL_DIR):
            progress("  fetching the separation models")
            self.status.downloading_models(0, models.EXPECTED_TOTAL_BYTES)
            models.prefetch(MODEL_DIR, progress=self.status.downloading_models)

        self.status.idle(songs_done=self._done)
        while True:
            job = self.claim()

            # Nothing to separate here, but there may be something asked for
            # in the cloud, which still needs a machine on a home connection
            # to go and download it. One app does both jobs; otherwise
            # choosing Modal for a link parks work nobody is coming for.
            if job is None:
                errand = Agent.claim(self)
                if errand is not None:
                    progress(f"fetch {errand['job_id']} for the cloud")
                    self._job_id = errand["job_id"]
                    try:
                        Agent.handle(self, errand, progress)
                        self._done += 1
                    except Exception as exc:
                        progress(f"  failed: {exc}")
                        self.status.failed(str(exc)[:200], classify(exc))
                    finally:
                        self._job_id = ""
                        self.status.idle(songs_done=self._done)
                    continue

            if job is None:
                if once:
                    progress("Nothing waiting.")
                    return
                self.register()               # heartbeat
                time.sleep(self.poll_seconds)
                continue
            self._job_id = job["job_id"]
            progress(f"job {job['job_id']}")
            self._song = ""
            self.register(busy=True)
            # Separation takes minutes; without a heartbeat the worker would
            # drop off the roster exactly while it is doing the work.
            stop = threading.Event()
            threading.Thread(
                target=self._heartbeat, args=(stop,), daemon=True
            ).start()
            try:
                self.handle(job, progress=progress)
            except Exception as exc:
                progress(f"  failed: {exc}")
                self.status.failed(str(exc)[:200], classify(exc))
                try:
                    self._post_json(f"/api/work/{job['job_id']}/failed", {"error": str(exc)})
                except Exception:
                    pass
            else:
                self._done += 1
            finally:
                stop.set()
                self._job_id = ""
                self.status.idle(songs_done=self._done)
            if once:
                return

    def _heartbeat(self, stop: "threading.Event") -> None:
        """Say we are still alive, to both readers.

        The server needs it so the job is not handed to another machine. The
        status file needs it just as much: the UI calls a status older than
        ninety seconds dead, and the vocal split alone runs for minutes without
        producing an event, so a working machine was reporting itself stopped
        halfway through every song.
        """
        while not stop.wait(20):
            self.status.touch()
            self._report()
            try:
                self.register(busy=True)
            except Exception:
                pass


def pair(base_url: str, code: str, label: str) -> str:
    """Trade a pairing code from the app for this machine's own token.

    The token that comes back may claim work and hand it back, and nothing
    else -- it cannot read the library or touch the account.
    """
    payload = json.dumps({"code": code, "label": label}).encode()
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/api/auth/pair/claim", data=payload,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)["token"]


def sign_in(base_url: str, email: str, password: str) -> str:
    payload = json.dumps({"email": email, "password": password}).encode()
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/api/auth/login", data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)["token"]
