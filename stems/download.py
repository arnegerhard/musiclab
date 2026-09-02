"""Pull the audio track off a YouTube (or other yt-dlp supported) URL."""

from __future__ import annotations

import re
import urllib.request
import unicodedata
from dataclasses import dataclass
from pathlib import Path

# 44.1kHz stereo WAV: what every separation model here expects natively.
SAMPLE_RATE = 44100


@dataclass
class Source:
    path: Path
    title: str
    uploader: str
    duration: float
    webpage_url: str
    video_id: str
    # Where the cover image can be fetched from, when the source had one.
    thumbnail_url: str = ""


def slugify(value: str, limit: int = 60) -> str:
    """A slug safe to use as a directory name and a URL path segment.

    Accents are folded to their base letters and anything still not ASCII is
    dropped. \\w kept them before, which is fine for a filename and fatal for a
    path: the deployment's HTTP layer decodes path segments as ASCII and
    refuses the request outright, so a song with an umlaut in its title
    separated perfectly and then could not be opened.
    """
    value = unicodedata.normalize("NFKD", value)
    value = value.encode("ascii", "ignore").decode("ascii")
    value = re.sub(r"[^\w\s-]", "", value).strip()
    value = re.sub(r"[\s_-]+", "-", value)
    # A title with nothing ASCII in it at all still gets a usable name; the
    # video id appended by the caller keeps it unique.
    return value[:limit].strip("-").lower() or "track"


def fetch_cover(url: str, destination: Path) -> bool:
    """Save the cover image beside the stems.

    Only ever a nicety: a track with no cover plays exactly as well, so every
    failure here is swallowed. It is what the lock screen shows, and a lock
    screen is mostly picture.
    """
    if not url:
        return False
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "Musiclab"})
        with urllib.request.urlopen(request, timeout=20) as response:
            data = response.read(4 << 20)
        if not data:
            return False
        destination.write_bytes(data)
        return True
    except Exception:
        return False


def adopt(audio: Path, dest_dir: Path, metadata: dict) -> Source:
    """Take audio that arrived some other way and make it look like a download.

    The app fetches from YouTube itself, because YouTube answers a phone on a
    home or carrier address and refuses a datacenter one. What lands here is
    whatever stream the phone got, so it still has to be normalised to the
    44.1 kHz stereo WAV every model expects.
    """
    import subprocess

    from .media import ffmpeg_path

    dest_dir.mkdir(parents=True, exist_ok=True)
    wav = dest_dir / "source.wav"
    result = subprocess.run(
        [
            ffmpeg_path(), "-y", "-loglevel", "error",
            "-i", str(audio),
            "-ar", str(SAMPLE_RATE), "-ac", "2",
            str(wav),
        ],
        capture_output=True,
    )
    if result.returncode != 0 or not wav.exists():
        raise RuntimeError(
            f"could not decode the uploaded audio: {result.stderr.decode()[:200]}"
        )

    duration = float(metadata.get("duration") or 0.0)
    if duration <= 0:
        import soundfile as sf

        duration = sf.info(str(wav)).duration

    return Source(
        path=wav,
        title=metadata.get("title") or "Unknown title",
        uploader=metadata.get("uploader") or "",
        duration=duration,
        webpage_url=metadata.get("url") or "",
        video_id=metadata.get("video_id") or "",
    )


def fetch(url: str, dest_dir: Path, progress=None) -> Source:
    """Download the best audio stream and decode it to a 44.1kHz stereo WAV."""
    import subprocess

    import yt_dlp

    from .media import ffmpeg_path

    dest_dir.mkdir(parents=True, exist_ok=True)

    def hook(status):
        if progress is None:
            return
        if status.get("status") == "downloading":
            total = status.get("total_bytes") or status.get("total_bytes_estimate")
            done = status.get("downloaded_bytes") or 0
            if total:
                progress(done / total)
        elif status.get("status") == "finished":
            progress(1.0)

    options = {
        "format": "bestaudio/best",
        "outtmpl": str(dest_dir / "download.%(ext)s"),
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "progress_hooks": [hook],
    }

    with yt_dlp.YoutubeDL(options) as ydl:
        info = ydl.extract_info(url, download=True)

    downloaded = next((p for p in sorted(dest_dir.glob("download.*")) if p.is_file()), None)
    if downloaded is None:
        raise RuntimeError("yt-dlp downloaded nothing")

    # yt-dlp is asked only to fetch, never to convert. Its audio postprocessor
    # wants both `ffmpeg` and `ffprobe` on disk under exactly those names, and
    # a packaged worker has neither -- while this is the same normalisation an
    # uploaded file already goes through. Models want 44.1k stereo.
    wav = dest_dir / "source.wav"
    result = subprocess.run(
        [
            ffmpeg_path(), "-y", "-loglevel", "error",
            "-i", str(downloaded),
            "-ar", str(SAMPLE_RATE), "-ac", "2",
            str(wav),
        ],
        capture_output=True,
    )
    if result.returncode != 0 or not wav.exists():
        raise RuntimeError(f"could not decode the download: {result.stderr.decode()[:200]}")
    downloaded.unlink(missing_ok=True)

    return Source(
        path=wav,
        title=info.get("title") or "Unknown title",
        uploader=info.get("uploader") or info.get("channel") or "",
        duration=float(info.get("duration") or 0.0),
        webpage_url=info.get("webpage_url") or url,
        video_id=info.get("id") or "",
        thumbnail_url=info.get("thumbnail") or "",
    )
