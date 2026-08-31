"""Convert already-separated tracks to a different storage format."""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from .config import OUT_DIR
from .pipeline import _encode, _encode_spatial, resolve_format


def job_dirs(out_dir: Path = OUT_DIR) -> list[Path]:
    return sorted(p.parent for p in out_dir.glob("*/manifest.json"))


def directory_size(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def convert(job_dir: Path, audio_format: str, progress=None) -> dict:
    """Re-encode one track's masters, then drop what is no longer needed."""
    fmt = resolve_format(audio_format)
    manifest_path = job_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text())

    def emit(**event):
        if progress:
            progress(event)

    before = directory_size(job_dir)
    previous = manifest.get("format", "wav")
    previous_lossless = resolve_format(previous).lossless if previous in ("wav", "flac") else False
    if not previous_lossless and not fmt.lossless:
        emit(kind="warn", message=f"{job_dir.name}: {previous} is already lossy; re-encoding loses more")

    stems_dir = job_dir / "stems"
    spatial_dir = job_dir / "spatial"

    for entry in manifest.get("stems", []):
        old = job_dir / entry["file"]
        if not old.exists():
            emit(kind="warn", message=f"missing {entry['file']}")
            continue

        new = stems_dir / f"{entry['name']}{fmt.extension}"
        if new.resolve() != old.resolve():
            if not _encode(old, new, fmt.codec_args):
                emit(kind="warn", message=f"could not encode {entry['name']}")
                continue
            old.unlink()
        entry["file"] = f"stems/{new.name}"
        entry["format"] = fmt.key

        entry.pop("preview", None)
        spatial = spatial_dir / f"{entry['name']}.m4a"
        if not spatial.exists():
            _encode_spatial(new, spatial)
        entry["spatial"] = f"spatial/{spatial.name}" if spatial.exists() else None

        emit(kind="stem", name=entry["name"])

    # The stereo preview tier existed only for the browser mixer, which is gone.
    stale_previews = job_dir / "previews"
    if stale_previews.exists():
        shutil.rmtree(stale_previews, ignore_errors=True)

    source_name = manifest.get("source_file")
    if source_name:
        old_source = job_dir / source_name
        new_source = job_dir / f"source{fmt.extension}"
        if old_source.exists() and new_source.resolve() != old_source.resolve():
            if _encode(old_source, new_source, fmt.codec_args):
                old_source.unlink()
                manifest["source_file"] = new_source.name

    manifest["format"] = fmt.key
    manifest_path.write_text(json.dumps(manifest, indent=2))

    after = directory_size(job_dir)
    return {"name": job_dir.name, "before": before, "after": after}
