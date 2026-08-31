"""Resolve stage models against whatever audio-separator actually ships.

Upstream renames checkpoints between releases, so stages ask for a model by
keyword (see config.Stage) and we match it here against the live registry.
"""

from __future__ import annotations

import logging
from functools import lru_cache

MODEL_SUFFIXES = (".ckpt", ".onnx", ".pth", ".yaml", ".th")


def _walk(node, path=()):
    """Flatten the registry's nested arch -> ... -> filename mapping."""
    if isinstance(node, dict):
        for key, value in node.items():
            yield from _walk(value, path + (str(key),))
    elif isinstance(node, str):
        yield path, node
    elif isinstance(node, (list, tuple)):
        for value in node:
            yield from _walk(value, path)


@lru_cache(maxsize=1)
def available_models() -> tuple[tuple[str, str], ...]:
    """(architecture, filename) for every model audio-separator can fetch."""
    from audio_separator.separator import Separator

    registry = Separator(info_only=True, log_level=logging.ERROR).list_supported_model_files()

    found: dict[str, str] = {}
    for path, value in _walk(registry):
        # The registry also carries stem-name strings ("vocals", "drums") that
        # are descriptions, not downloadable files. Only keep real checkpoints.
        if value.lower().endswith(MODEL_SUFFIXES) and value not in found:
            found[value] = path[0] if path else "?"
    return tuple((arch, name) for name, arch in found.items())


def resolve(
    preferred: tuple[str, ...],
    keyword_sets: tuple[tuple[str, ...], ...],
) -> str | None:
    """Pick a model: known-good names first, then a keyword search.

    The keyword fallback keeps working after an upstream rename, but it can
    land on a fork or a bare config file, so exact names are tried first.
    """
    models = available_models()
    names = {filename for _arch, filename in models}
    for name in preferred:
        if name in names:
            return name

    for keywords in keyword_sets:
        matches = [
            filename
            for _arch, filename in models
            if all(k.lower() in filename.lower() for k in keywords)
        ]
        if matches:
            # MDXC ships "config_*.yaml" sidecars next to real checkpoints;
            # those are not loadable models, so sink them. Then shortest name
            # wins, as that tends to be the plain variant rather than a fork.
            ranked = sorted(
                matches,
                key=lambda m: (m.lower().startswith("config"), len(m), m),
            )
            return ranked[0]
    return None


# Only used to draw the progress bar. audio-separator's downloader reports
# nothing, so progress is inferred from how much the model directory has
# grown, and that needs a target to divide by. Being a little off makes the
# bar slightly wrong, which is why the UI says "about".
EXPECTED_TOTAL_BYTES = 1_400_000_000


def missing(model_dir) -> list[str]:
    """Which stage models are not on disk yet."""
    from pathlib import Path

    from .config import ALL_STAGES

    directory = Path(model_dir)
    absent = []
    for stage in ALL_STAGES:
        name = resolve(stage.preferred, stage.model_keywords)
        if name and not (directory / name).exists():
            absent.append(name)
    return absent


def directory_bytes(path) -> int:
    from pathlib import Path

    root = Path(path)
    if not root.exists():
        return 0
    return sum(f.stat().st_size for f in root.rglob("*") if f.is_file())


def prefetch(model_dir, progress=None) -> None:
    """Download whatever stage models are missing, reporting progress.

    Done up front rather than on first use so a fresh worker can say what it is
    waiting for, instead of appearing to hang for several minutes on its first
    song.
    """
    import logging
    import threading
    import time
    from pathlib import Path

    directory = Path(model_dir)
    directory.mkdir(parents=True, exist_ok=True)
    absent = missing(directory)
    if not absent:
        return

    from audio_separator.separator import Separator

    separator = Separator(
        log_level=logging.ERROR, model_file_dir=str(directory), output_dir="/tmp"
    )

    started = directory_bytes(directory)
    finished = threading.Event()

    def watch():
        while not finished.wait(0.5):
            if progress:
                progress(directory_bytes(directory) - started, EXPECTED_TOTAL_BYTES)

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    try:
        for name in absent:
            separator.download_model_files(name)
    finally:
        finished.set()
        watcher.join(timeout=2)
    if progress:
        progress(EXPECTED_TOTAL_BYTES, EXPECTED_TOTAL_BYTES)
