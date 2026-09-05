"""The separation cascade: split the mix, then split the splits."""

from __future__ import annotations

import logging
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from . import models
from .config import SOURCE_INPUT, Stage
import contextlib
import importlib

from .download import slugify

LABEL_RE = re.compile(r"\(([^()]+)\)(?!.*\([^()]+\))")


@dataclass
class Stem:
    name: str
    path: Path
    stage: str
    parent: str | None = None
    children: list[str] = field(default_factory=list)

    @property
    def is_leaf(self) -> bool:
        return not self.children


def _label_of(filename: str) -> str | None:
    """audio-separator names outputs '<input>_(Vocals)_<model>.wav'."""
    match = LABEL_RE.search(Path(filename).stem)
    return match.group(1).strip() if match else None


def _stem_name(label: str, stage: Stage) -> str:
    lowered = label.lower()
    # Ordered: 'Backing Vocals' must hit 'backing' before it hits 'vocals'.
    for needle, name in stage.rename.items():
        if needle in lowered:
            return name
    return slugify(label).replace("-", "_")


class Cascade:
    """Runs stages in order, feeding each stage the stem it asked for."""

    def __init__(
        self,
        work_dir: Path,
        stem_dir: Path,
        model_dir: Path,
        progress=None,
        log_level: int = logging.ERROR,
    ):
        self.work_dir = work_dir
        self.stem_dir = stem_dir
        self.model_dir = model_dir
        self.progress = progress
        self.log_level = log_level
        self._separator = None
        self._loaded_model: str | None = None

    def _emit(self, **event):
        if self.progress:
            self.progress(event)

    def _get_separator(self, output_dir: Path):
        from audio_separator.separator import Separator

        if self._separator is None:
            self.model_dir.mkdir(parents=True, exist_ok=True)
            self._separator = Separator(
                log_level=self.log_level,
                model_file_dir=str(self.model_dir),
                output_dir=str(output_dir),
                output_format="WAV",
            )
        else:
            # Reuse the instance so a loaded model stays warm across calls.
            self._separator.output_dir = str(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        return self._separator

    def run(self, source: Path, stages: list[Stage]) -> dict[str, Stem]:
        self.stem_dir.mkdir(parents=True, exist_ok=True)
        stems: dict[str, Stem] = {}

        for index, stage in enumerate(stages):
            model = models.resolve(stage.preferred, stage.model_keywords)
            if model is None:
                if stage.optional:
                    self._emit(
                        kind="stage_skipped",
                        stage=stage.key,
                        reason="no matching model available",
                    )
                    continue
                raise RuntimeError(f"No model found for required stage '{stage.key}'")

            if stage.source == SOURCE_INPUT:
                input_path = source
                parent = None
            else:
                parent_stem = stems.get(stage.source)
                if parent_stem is None:
                    self._emit(
                        kind="stage_skipped",
                        stage=stage.key,
                        reason=f"upstream stem '{stage.source}' was not produced",
                    )
                    continue
                input_path = parent_stem.path
                parent = parent_stem.name

            self._emit(
                kind="stage_start",
                stage=stage.key,
                title=stage.title,
                model=model,
                index=index,
                total=len(stages),
            )

            produced = self._run_stage(
                stage, model, input_path, parent,
                index=index, total=len(stages),
            )
            for stem in produced:
                stems[stem.name] = stem
            if parent and parent in stems:
                stems[parent].children = [s.name for s in produced]

            self._emit(
                kind="stage_done",
                stage=stage.key,
                stems=[s.name for s in produced],
            )

        return stems

    def _run_stage(
        self, stage: Stage, model: str, input_path: Path, parent: str | None,
        index: int = 0, total: int = 1,
    ) -> list[Stem]:
        raw_dir = self.work_dir / f"raw_{stage.key}"
        raw_dir.mkdir(parents=True, exist_ok=True)

        separator = self._get_separator(raw_dir)
        if self._loaded_model != model:
            # Which of how many, so the wait can be a bar rather than a
            # spinner. On a cold GPU container this is most of the wait,
            # and it is the one part of it with a countable end.
            self._emit(
                kind="model_load", stage=stage.key, model=model,
                index=index, total=total,
            )
            separator.load_model(model_filename=model)
            self._loaded_model = model
        else:
            # A loaded model captured the output directory it was built with,
            # so a reused model would otherwise write into the previous
            # stage's folder and we would never find its outputs.
            separator.model_instance.output_dir = str(raw_dir)

        # The model is up; what follows is the separation itself, which is the
        # long part. Without this the last thing anyone heard was "loading the
        # models", so the whole separation ran under the label of the step
        # before it and the bar sat still.
        self._emit(
            kind="model_ready", stage=stage.key, model=model,
            index=index, total=total,
        )

        with _watched_inference(self._emit, index=index, total=total):
            outputs = separator.separate(str(input_path))

        produced: list[Stem] = []
        for output in outputs:
            path = Path(output)
            if not path.is_absolute():
                path = raw_dir / path
            if not path.exists():
                # Belt and braces: find it wherever the separator put it.
                matches = sorted(self.work_dir.rglob(Path(output).name))
                if not matches:
                    self._emit(
                        kind="stem_missing", stage=stage.key, file=Path(output).name
                    )
                    continue
                path = matches[0]

            label = _label_of(path.name)
            if label is None:
                continue

            name = _stem_name(label, stage)
            final = self.stem_dir / f"{name}.wav"
            shutil.move(str(path), final)
            produced.append(Stem(name=name, path=final, stage=stage.key, parent=parent))

        return produced


# The separation itself is where a song spends most of its life -- eight of
# the ten minutes a Mac takes -- and audio-separator offers no way to ask how
# far along it is. What it does do is drive its chunks through tqdm, so that
# is the handle: for the duration of one stage, tqdm in those modules is a
# shim that counts the same iterations and says so.
#
# Patching somebody else's global is not free, and it is worth being plain
# about why it is acceptable here: it is confined to one call, restored in a
# finally, and falls back to doing nothing at all if the module ever stops
# looking the way it does today. The alternative was a bar that sat at fifty
# percent for eight minutes.
@contextlib.contextmanager
def _watched_inference(emit, index: int, total: int):
    modules = []
    for name in ("mdxc_separator", "mdx_separator", "vr_separator"):
        try:
            modules.append(importlib.import_module(
                f"audio_separator.separator.architectures.{name}"
            ))
        except Exception:
            continue

    patched = [m for m in modules if hasattr(m, "tqdm")]
    if not patched:
        yield
        return

    originals = {m: m.tqdm for m in patched}

    def watching(iterable=None, *args, **kwargs):
        original = originals[patched[0]]
        if iterable is None:
            return original(*args, **kwargs)
        try:
            steps = len(iterable)
        except TypeError:
            return original(iterable, *args, **kwargs)

        def counted():
            for done, item in enumerate(iterable, start=1):
                yield item
                if steps:
                    emit(
                        kind="inference_progress",
                        fraction=done / steps, index=index, total=total,
                    )

        return original(counted(), *args, total=steps, **kwargs)

    try:
        for module in patched:
            module.tqdm = watching
        yield
    finally:
        for module, original in originals.items():
            module.tqdm = original
