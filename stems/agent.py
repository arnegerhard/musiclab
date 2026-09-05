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
        self._name = ""
        self._last_report_error = ""
        # Whoever started this. Checked while idle so an orphan stops itself.
        self._parent_pid = __import__("os").getppid()
        self._song = ""
        self._job_id = ""
        self._done = 0

    # MARK: transport

    # Long enough for a slow reply, short enough that the loop keeps turning.
    # Every call used to wait five minutes, which is right for pushing forty
    # megabytes and wrong for a two-hundred-byte poll: one slow answer froze
    # the worker, its status file went stale, and the app called a Mac that
    # was sitting right there offline.
    POLL_TIMEOUT_SECONDS = 30
    TRANSFER_TIMEOUT_SECONDS = 300

    def _request(
        self,
        path: str,
        data: bytes | None = None,
        content_type: str | None = None,
        timeout: float | None = None,
    ):
        request = urllib.request.Request(f"{self.base}{path}", data=data)
        request.add_header("Authorization", f"Bearer {self.token}")
        if content_type:
            request.add_header("Content-Type", content_type)
        with urllib.request.urlopen(
            request, timeout=timeout or self.POLL_TIMEOUT_SECONDS
        ) as response:
            body = response.read()
        return json.loads(body) if body else {}

    def _download(self, path: str, destination: Path) -> None:
        """Pull a file from the server, streamed, with this worker's token."""
        request = urllib.request.Request(f"{self.base}{path}")
        request.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(
            request, timeout=self.TRANSFER_TIMEOUT_SECONDS
        ) as response:
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
        # Sending the audio or the stems: megabytes, so it gets the patience
        # a poll does not.
        return self._request(
            path, b"".join(parts), f"multipart/form-data; boundary={boundary}",
            timeout=self.TRANSFER_TIMEOUT_SECONDS,
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

    # yt-dlp calls its progress hook for every chunk it receives, and every
    # report is an HTTPS round trip: sending one per chunk turned a two second
    # download into thirty-five bytes a second. Only these two arrive at that
    # rate, and only these two are worth dropping -- everything else is a step
    # changing, which must always get through.
    CHATTY_EVENTS = frozenset({"download_progress", "encode_progress"})
    REPORT_INTERVAL_SECONDS = 1.0

    def report(self, **event) -> None:
        """Say what happened, and show what the server says it means.

        The worker used to decide for itself which stage an event belonged to
        and how full the bar should be, and so did the server, in a second
        copy of the same table. They drifted, and every progress bug of the
        last few days lived in the gap between them.
        """
        if self.status is None or not self._job_id:
            return
        kind = event.get("kind", "")
        if kind in self.CHATTY_EVENTS:
            now = time.time()
            if now - getattr(self, "_reported_at", 0.0) < self.REPORT_INTERVAL_SECONDS:
                return
            self._reported_at = now

        try:
            visible = self._post_json(
                f"/api/work/{self._job_id}/event",
                {**event, "worker": self._name},
            )
        except Exception as exc:
            # A dropped report must never fail a job, but it must not vanish
            # either: a bare `return` here hid a missing attribute for a whole
            # run, and the Mac's panel sat on "Idle" while it was downloading.
            if kind != self._last_report_error:
                self._last_report_error = kind
                print(f"    (report {kind} failed: {exc})", flush=True)
            return
        if not visible:
            return
        if title := visible.get("title"):
            self._song = title
        self.status.apply(visible, song=self._song)

    def handle(self, job: dict, progress=print) -> None:
        job_id = job["job_id"]
        url = job.get("url")
        track = job.get("track")
        matched = None
        title = (track or {}).get("title", "") if track else ""
        self._song = title
        self.report(kind="matching")

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

            # Keyword arguments, because that is how the pipeline emits:
            # `emit(kind="decode_start")`. Taking a dict here instead meant
            # every fetch raised the moment the download finished, and the
            # only trace was a line Python was still holding in a buffer.
            source = download.fetch(
                url, Path(staging),
                progress=lambda f: self.report(
                    kind="download_progress", fraction=f
                ),
                emit=lambda **event: self.report(**event),
            )
            self._song = source.title or title
            # The server re-decodes anyway, so send the compact original
            # rather than the WAV it was expanded into.
            audio = next(
                (p for p in Path(staging).glob("source.*") if p.suffix != ".wav"),
                source.path,
            )
            size = audio.stat().st_size / 1e6
            progress(f"  uploading {size:.0f} MB")
            # Named for where it is going: this is the Mac handing the audio
            # to the cloud, not the end of the job.
            self.report(kind="handing_over", megabytes=size)
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

        def computer_name() -> str:
            """What its owner calls this Mac, not what the router does.

            platform.node() is the hostname, which on a home network is
            whatever DHCP handed out -- "Mac-121.lan" here -- and it changes
            with the lease. ComputerName is the one in System Settings, the
            one that already appears on the phone because pairing recorded it.
            """
            try:
                name = subprocess.run(
                    ["/usr/sbin/scutil", "--get", "ComputerName"],
                    capture_output=True, text=True, timeout=5,
                ).stdout.strip()
            except Exception:
                name = ""
            return name or platform.node().split(".")[0] or "A Mac"

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
            "name": computer_name(),
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
        self._song = title
        self.report(kind="matching")

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
                self.report(kind="download_start")
                uploaded = out / "source"
                self._download(job["source_path"], uploaded)

            progress("  separating locally")
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
            self.report(kind="encode_start")
            with tarfile.open(bundle, "w") as tar:
                tar.add(result.job_dir, arcname=result.job_dir.name)
            size = bundle.stat().st_size / 1e6
            progress(f"  uploading {size:.0f} MB")
            self.report(kind="uploading", megabytes=size)
            self._post_file(
                f"/api/work/{job_id}/result",
                bundle,
                {"slug": result.job_dir.name},
                field="archive",
            )
            # Nothing is kept: the temporary directory goes with this block.
            shutil.rmtree(result.job_dir, ignore_errors=True)
        progress("  handed over")

    # yt-dlp calls its progress hook for every chunk it receives -- many times
    # a second -- and each report is an HTTPS round trip to the server. Sending
    # one per chunk turned a two-second download into thirty-five bytes a
    # second, because the download spent its life waiting on the reports about
    # it. A stage change always goes out; a moved bar waits its turn.
    REPORT_INTERVAL_SECONDS = 1.0

    def _note(self, event: dict, progress) -> None:
        """Forward a pipeline event, and print the readable ones.

        No mapping here any more. What a `model_ready` means, and how full a
        bar should be for it, is the server's to say -- there was a second
        copy of that table here, and it was the second copy that was wrong.
        """
        kind = event.get("kind")
        if kind == "download_done":
            self._song = event.get("title", self._song)
            progress(f'    got "{self._song}"')
        elif kind == "stage_start":
            progress(f"    {event['title']}")
        self.report(**event)

    def run(self, once: bool = False, progress=print) -> None:
        ensure_on_path()
        self.status = Status()
        self._song = ""
        self._job_id = ""
        self._done = 0
        ensure_on_path()

        self.worker_id = self.register()
        info = self.describe()
        self._name = info["name"]
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
                    self._song = ""
                    # The same heartbeat a full job gets. Without it the Mac
                    # fell off the roster sixty seconds into a fetch and the
                    # app called it offline while it was downloading.
                    self.register(busy=True)
                    stop = threading.Event()
                    threading.Thread(
                        target=self._heartbeat, args=(stop,), daemon=True
                    ).start()
                    try:
                        Agent.handle(self, errand, progress)
                        self._done += 1
                    except Exception as exc:
                        progress(f"  failed: {exc}")
                        self.status.failed(str(exc)[:200], classify(exc))
                        # And tell the server, which is the part that was
                        # missing: the job stayed "Downloading the audio" with
                        # nobody downloading it until the stale sweep noticed
                        # three minutes later, then failed the same way again.
                        try:
                            self._post_json(
                                f"/api/fetch/{errand['job_id']}/failed",
                                {"error": str(exc)[:400]},
                            )
                        except Exception:
                            pass
                    finally:
                        stop.set()
                        self._job_id = ""
                        self.status.idle(songs_done=self._done)
                        self.register()
                    continue

            if job is None:
                if once:
                    progress("Nothing waiting.")
                    return
                # Two readers, and until now only one of them was told. The
                # server heard this heartbeat and knew the Mac was alive; the
                # panel on the Mac itself reads a file that nothing touched
                # while idle, so after ninety seconds it decided its own
                # worker had died -- which is the state it spends most of its
                # life in.
                self.register()
                self.status.touch()
                time.sleep(self.poll_seconds)
                if self._orphaned():
                    progress("The app that started this worker has gone.")
                    self.status.stopped()
                    return
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

    def _orphaned(self) -> bool:
        """Whether the app that started this worker has gone.

        A worker outlives its app: quitting the menu bar app, or killing it,
        leaves the interpreter running, still claiming songs and still writing
        the status file that the next app to start will read. Six of them
        accumulated here in one afternoon, competing for the same jobs and
        making one download look like a stall.

        macOS reparents an orphan to launchd, so a parent of 1 is the signal.
        """
        import os

        return self._parent_pid > 1 and os.getppid() != self._parent_pid

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
            # Two different claims, and both have to be made. register() says
            # this machine is alive; the event says it still holds this song.
            # A separation stage runs for minutes without emitting anything,
            # and without this the job was offered to somebody else while the
            # Mac was in the middle of it.
            self.report(kind="still_working")
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
