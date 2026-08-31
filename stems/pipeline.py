"""Orchestration: URL in, a folder of stems and a manifest out."""

from __future__ import annotations

import json
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf

from . import download
from .config import (
    DEFAULT_FORMAT,
    FORMATS,
    MODEL_DIR,
    OUT_DIR,
    STAGES_BY_KEY,
    AudioFormat,
    stem_sort_key,
)
from .separate import Cascade, Stem


@dataclass
class Result:
    job_dir: Path
    manifest: dict


def _measure(path: Path) -> dict:
    """Peak and RMS in dBFS, so the mixer can show a level at a glance.

    Always run against the WAV the models produced: libsndfile reads WAV and
    FLAC but not AAC, and measuring before encoding is more accurate anyway.
    """
    data, _rate = sf.read(str(path), dtype="float32", always_2d=True)
    peak = float(np.abs(data).max()) if data.size else 0.0
    rms = float(np.sqrt(np.mean(np.square(data)))) if data.size else 0.0

    def db(value: float) -> float | None:
        return round(20 * np.log10(value), 1) if value > 1e-9 else None

    return {"peak_db": db(peak), "rms_db": db(rms), "silent": peak < 1e-4}


def _encode(source: Path, dest: Path, args: tuple[str, ...]) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-i", str(source),
            *args,
            # Lets a player start before it has the whole file. Harmless on
            # formats that do not use the moov atom.
            "-movflags", "+faststart",
            str(dest),
        ],
        capture_output=True,
    )
    if result.returncode != 0 or not dest.exists():
        # -movflags is MP4-only; retry without it for FLAC, MP3 and WAV.
        result = subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(source), *args, str(dest)],
            capture_output=True,
        )
    return result.returncode == 0 and dest.exists()


def _encode_preview(source: Path, dest: Path, mono: bool = False) -> bool:
    """A compressed sidecar, for a consumer the master format does not suit.

    * stereo, for the browser mixer, when the master is lossless. Fourteen
      FLAC stems at once is 200 MB of buffering, which wedges the tab.
    * mono, for the iOS spatial app. AVAudioEnvironmentNode only spatialises
      mono inputs -- a stereo source is passed through unpositioned -- and a
      point in a room is mono by definition anyway.
    """
    channels = ("-ac", "1") if mono else ()
    return _encode(
        source, dest, ("-c:a", "aac", "-b:a", "96k" if mono else "128k", *channels)
    )


def _reconstruction_error(source: Path, leaves: list[Path]) -> float | None:
    """How much of the original survives summing the leaf stems back together.

    Separation is not lossless, so this is a sanity check, not a guarantee:
    a large residual means a stage misbehaved.
    """
    try:
        original, _ = sf.read(str(source), dtype="float32", always_2d=True)
        total = None
        for leaf in leaves:
            data, _ = sf.read(str(leaf), dtype="float32", always_2d=True)
            if total is None:
                total = data
                continue
            # Stems can differ by a frame or two; sum over the common span.
            frames = min(len(total), len(data))
            channels = min(total.shape[1], data.shape[1])
            total = total[:frames, :channels] + data[:frames, :channels]
        if total is None:
            return None
        frames = min(len(original), len(total))
        channels = min(original.shape[1], total.shape[1])
        reference = original[:frames, :channels]
        residual = reference - total[:frames, :channels]
        denominator = float(np.sqrt(np.mean(np.square(reference))))
        if denominator < 1e-9:
            return None
        return round(float(np.sqrt(np.mean(np.square(residual)))) / denominator, 4)
    except Exception:
        return None


def selected_stages(vocals: bool = True, drums: bool = True):
    keys = ["base"] + (["vocals"] if vocals else []) + (["drums"] if drums else [])
    return [STAGES_BY_KEY[k] for k in keys]


def resolve_format(name: str | AudioFormat) -> AudioFormat:
    if isinstance(name, AudioFormat):
        return name
    if name not in FORMATS:
        raise ValueError(f"unknown format '{name}'; choose from {', '.join(FORMATS)}")
    return FORMATS[name]


def run(
    url: str,
    out_dir: Path = OUT_DIR,
    split_vocals: bool = True,
    split_drums: bool = True,
    progress=None,
    keep_source: bool = True,
    audio_format: str = DEFAULT_FORMAT,
    extra: dict | None = None,
) -> Result:
    def emit(**event):
        if progress:
            progress(event)

    fmt = resolve_format(audio_format)
    started = time.time()
    out_dir.mkdir(parents=True, exist_ok=True)

    emit(kind="download_start", url=url)
    staging = out_dir / f".staging-{int(started)}"
    staging.mkdir(parents=True, exist_ok=True)
    source = download.fetch(
        url, staging, progress=lambda f: emit(kind="download_progress", fraction=f)
    )
    emit(kind="download_done", title=source.title, duration=source.duration)

    # Name the job folder after the track now that we know what it is.
    job_dir = out_dir / f"{download.slugify(source.title)}-{source.video_id or int(started)}"
    if job_dir.exists():
        job_dir = Path(f"{job_dir}-{int(started)}")
    staging.rename(job_dir)
    source.path = job_dir / source.path.name

    work_dir = job_dir / ".work"
    stem_dir = job_dir / "stems"
    stages = selected_stages(split_vocals, split_drums)

    # The models emit WAV, and each stage reads the previous stage's output,
    # so separation happens entirely in the work directory. Only the finished
    # stems get encoded into the format the caller asked for.
    cascade = Cascade(
        work_dir=work_dir,
        stem_dir=work_dir / "wav",
        model_dir=MODEL_DIR,
        progress=progress,
    )
    stems: dict[str, Stem] = cascade.run(source.path, stages)

    emit(kind="analyse_start")
    ordered = sorted(stems.values(), key=lambda s: stem_sort_key(s.name))
    leaves = [s.path for s in ordered if s.is_leaf]
    # Measured before encoding, while everything is still uncompressed PCM.
    measurements = {s.name: _measure(s.path) for s in ordered}
    error = _reconstruction_error(source.path, leaves)

    emit(kind="encode_start", format=fmt.key, count=len(ordered))
    preview_dir = job_dir / "previews"
    spatial_dir = job_dir / "spatial"
    stem_entries = []

    for index, stem in enumerate(ordered):
        master = stem_dir / f"{stem.name}{fmt.extension}"
        if not _encode(stem.path, master, fmt.codec_args):
            emit(kind="encode_failed", stem=stem.name)
            continue

        # A lossy master is already small enough to stream, so it doubles as
        # the browser mixer's source instead of a third copy on disk.
        if fmt.streamable:
            preview_path = f"stems/{master.name}"
        else:
            preview = preview_dir / f"{stem.name}.m4a"
            preview_path = (
                f"previews/{preview.name}" if _encode_preview(stem.path, preview) else None
            )

        spatial = spatial_dir / f"{stem.name}.m4a"
        has_spatial = _encode_preview(stem.path, spatial, mono=True)

        stem_entries.append(
            {
                "name": stem.name,
                "label": stem.name.replace("_", " ").title(),
                "file": f"stems/{master.name}",
                "format": fmt.key,
                "preview": preview_path,
                "spatial": f"spatial/{spatial.name}" if has_spatial else None,
                "stage": stem.stage,
                "parent": stem.parent,
                "children": stem.children,
                "leaf": stem.is_leaf,
                **measurements[stem.name],
            }
        )
        emit(kind="encode_progress", done=index + 1, total=len(ordered))

    # The downloaded mix gets the same treatment; it was a 36 MB WAV.
    source_name = None
    if keep_source:
        encoded_source = job_dir / f"source{fmt.extension}"
        if _encode(source.path, encoded_source, fmt.codec_args):
            source_name = encoded_source.name
    if source.path.exists():
        source.path.unlink()

    manifest = {
        "title": source.title,
        "uploader": source.uploader,
        "duration": source.duration,
        "url": source.webpage_url,
        "video_id": source.video_id,
        "format": fmt.key,
        "source_file": source_name,
        "stems": stem_entries,
        "stages": [{"key": s.key, "title": s.title, "note": s.note} for s in stages],
        "reconstruction_error": error,
        "elapsed_seconds": round(time.time() - started, 1),
        # Provenance for tracks that arrived from a playlist rather than a URL.
        **(extra or {}),
    }

    (job_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    shutil.rmtree(work_dir, ignore_errors=True)

    emit(kind="done", job_dir=str(job_dir), stems=len(stem_entries))
    return Result(job_dir=job_dir, manifest=manifest)
