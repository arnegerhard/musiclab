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
