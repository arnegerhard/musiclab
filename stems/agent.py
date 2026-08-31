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
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from . import download, match


class Agent:
    def __init__(self, base_url: str, token: str, poll_seconds: float = 5.0):
        self.base = base_url.rstrip("/")
        self.token = token
        self.poll_seconds = poll_seconds

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

    def _post_file(self, path: str, file: Path, fields: dict[str, str]):
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
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"audio\"; "
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


def sign_in(base_url: str, email: str, password: str) -> str:
    payload = json.dumps({"email": email, "password": password}).encode()
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/api/auth/login", data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)["token"]
