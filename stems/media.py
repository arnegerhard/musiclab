"""Finding ffmpeg.

A packaged worker cannot assume Homebrew, so the wheel-shipped binary is the
fallback. The system one is preferred when present: it is what the developer
machine has been tested against.
"""

from __future__ import annotations

import shutil
from functools import lru_cache


@lru_cache(maxsize=1)
def ffmpeg_path() -> str:
    found = shutil.which("ffmpeg")
    if found:
        return found
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception as exc:
        raise RuntimeError(
            "ffmpeg was not found. Install it, or `pip install imageio-ffmpeg`."
        ) from exc


@lru_cache(maxsize=1)
def ensure_on_path() -> str:
    """Make `ffmpeg` findable by name, for code that shells out to it.

    audio-separator runs `ffmpeg -version` directly and pydub looks it up on
    PATH, so pointing our own calls at the wheel-shipped binary is not enough:
    it has to be reachable under its plain name. The wheel names it after its
    platform and version, so a small directory of links is what goes on PATH.
    """
    import os
    from pathlib import Path

    binary = Path(ffmpeg_path())
    if binary.name == "ffmpeg":
        return str(binary.parent)

    links = Path.home() / "Library" / "Caches" / "Musiclab" / "bin"
    links.mkdir(parents=True, exist_ok=True)
    link = links / "ffmpeg"
    if not link.exists() or link.resolve() != binary.resolve():
        link.unlink(missing_ok=True)
        link.symlink_to(binary)

    existing = os.environ.get("PATH", "")
    if str(links) not in existing.split(os.pathsep):
        os.environ["PATH"] = f"{links}{os.pathsep}{existing}"
    return str(links)
