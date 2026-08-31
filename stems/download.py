"""Pull the audio track off a YouTube (or other yt-dlp supported) URL."""

from __future__ import annotations

import re
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


def slugify(value: str, limit: int = 60) -> str:
    value = re.sub(r"[^\w\s-]", "", value, flags=re.UNICODE).strip()
    value = re.sub(r"[\s_-]+", "-", value)
    return value[:limit].strip("-").lower() or "track"


def fetch(url: str, dest_dir: Path, progress=None) -> Source:
    """Download the best audio stream and decode it to a 44.1kHz stereo WAV."""
    import yt_dlp

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
        "outtmpl": str(dest_dir / "source.%(ext)s"),
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "progress_hooks": [hook],
        "postprocessors": [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": "wav",
                "preferredquality": "0",
            }
        ],
        # Models are trained on 44.1k stereo; normalise here so every stage
        # downstream sees the same shape regardless of the upload's format.
        "postprocessor_args": {
            "extractaudio": ["-ar", str(SAMPLE_RATE), "-ac", "2"],
        },
    }

    with yt_dlp.YoutubeDL(options) as ydl:
        info = ydl.extract_info(url, download=True)

    wav = dest_dir / "source.wav"
    if not wav.exists():
        candidates = sorted(dest_dir.glob("source.*"))
        raise RuntimeError(
            f"yt-dlp produced no WAV (found: {[c.name for c in candidates]})"
        )

    return Source(
        path=wav,
        title=info.get("title") or "Unknown title",
        uploader=info.get("uploader") or info.get("channel") or "",
        duration=float(info.get("duration") or 0.0),
        webpage_url=info.get("webpage_url") or url,
        video_id=info.get("id") or "",
    )
