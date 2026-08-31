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

from . import download, match, pipeline


class Agent:
    def __init__(self, base_url: str, token: str, poll_seconds: float = 5.0):
        self.base = base_url.rstrip("/")
        self.token = token
        self.poll_seconds = poll_seconds
        self.worker_id = ""

    # MARK: transport

    def _request(self, path: str, data: bytes | None = None, content_type: str | None = None):
        request = urllib.request.Request(f"{self.base}{path}", data=data)
        request.add_header("Authorization", f"Bearer {self.token}")
        if content_type:
            request.add_header("Content-Type", content_type)
        with urllib.request.urlopen(request, timeout=300) as response:
            body = response.read()
        return json.loads(body) if body else {}

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
        import platform
        import subprocess

        def sysctl(key: str) -> str:
            try:
                return subprocess.run(
                    ["sysctl", "-n", key], capture_output=True, text=True, timeout=5
                ).stdout.strip()
            except Exception:
                return ""

        memory = sysctl("hw.memsize")
        try:
            import torch

            gpu = torch.backends.mps.is_available()
        except Exception:
            gpu = False

        return {
            "name": platform.node().split(".")[0],
            "chip": sysctl("machdep.cpu.brand_string") or platform.machine(),
            "cores": int(sysctl("hw.ncpu") or 0),
            "memory_gb": round(int(memory) / 1e9, 1) if memory.isdigit() else 0,
            "gpu": gpu,
            "version": "1",
        }

    def register(self, busy: bool = False) -> str:
        reply = self._post_json(
            "/api/workers/register", {**self.describe(), "busy": busy}
        )
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
            progress("  separating locally")
            result = pipeline.run(
                url,
                out_dir=out,
                split_vocals=job.get("split_vocals", True),
                split_drums=job.get("split_drums", True),
                audio_format=job.get("audio_format", "flac"),
                progress=lambda e: self._note(e, progress),
            )

            bundle = out / "result.tar"
            progress("  packing")
            with tarfile.open(bundle, "w") as tar:
                tar.add(result.job_dir, arcname=result.job_dir.name)
            size = bundle.stat().st_size / 1e6
            progress(f"  uploading {size:.0f} MB")
            self._post_file(
                f"/api/work/{job_id}/result",
                bundle,
                {"slug": result.job_dir.name},
                field="archive",
            )
            # Nothing is kept: the temporary directory goes with this block.
            shutil.rmtree(result.job_dir, ignore_errors=True)
        progress("  handed over")

    @staticmethod
    def _note(event: dict, progress) -> None:
        kind = event.get("kind")
        if kind == "stage_start":
            progress(f"    {event['title']}")
        elif kind == "download_done":
            progress(f"    got \"{event['title']}\"")

    def run(self, once: bool = False, progress=print) -> None:
        self.worker_id = self.register()
        progress(f"Worker {self.worker_id} watching {self.base}")
        info = self.describe()
        progress(f"  {info['chip']}, {info['cores']} cores, GPU: {info['gpu']}")
        while True:
            job = self.claim()
            if job is None:
                if once:
                    progress("Nothing waiting.")
                    return
                self.register()               # heartbeat
                time.sleep(self.poll_seconds)
                continue
            progress(f"job {job['job_id']}")
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
                try:
                    self._post_json(f"/api/work/{job['job_id']}/failed", {"error": str(exc)})
                except Exception:
                    pass
            finally:
                stop.set()
            if once:
                return

    def _heartbeat(self, stop: "threading.Event") -> None:
        while not stop.wait(20):
            try:
                self.register(busy=True)
            except Exception:
                pass


def sign_in(base_url: str, email: str, password: str) -> str:
    payload = json.dumps({"email": email, "password": password}).encode()
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/api/auth/login", data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)["token"]
