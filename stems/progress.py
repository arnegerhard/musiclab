"""What a pipeline event means, decided in exactly one place.

A song is worked on by two kinds of machine -- a Mac and a GPU container --
and both run the same pipeline, which emits the same events. Until now each
of them turned those events into a stage and a fraction separately: once in
the agent, once in the server. Same vocabulary, two implementations, kept in
step by hand.

Every progress bug of the last few days lived in that gap. "Separating" never
appeared because one mapping was missing an event the other had. The bar stuck
at five percent because one had moved to per-step fractions and the other had
not. Each fix had to be made twice, and one of them was forgotten.

So the mapping is a pure function, here, and both callers use it. It takes an
event and returns what a person should be told; it talks to nothing and can be
tested without a network, a Mac, or a GPU.
"""

from __future__ import annotations

from dataclasses import dataclass

from .states import Stage


@dataclass(frozen=True)
class Update:
    """What to show, once an event has been understood."""

    #  None where the event is worth writing down but changes nothing anyone
    #  is watching -- a missing stem is a warning, not a step.
    stage: Stage | None = None
    #  "" clears the aside under the step; None leaves whatever the step
    #  already had, for events that refine a step rather than begin one.
    detail: str | None = ""
    #  Within this step, where the step has a countable end. None means the
    #  step is under way and cannot say how far.
    fraction: float | None = None
    #  Worth putting in the job's log rather than only on screen.
    note: str = ""
    title: str = ""


def _share(event: dict, done_key: str = "index") -> float | None:
    total = event.get("total")
    if not total:
        return None
    return max(0.0, min(1.0, float(event.get(done_key, 0)) / float(total)))


def _of(event: dict, done_key: str = "index", offset: int = 1) -> str:
    total = event.get("total")
    if not total:
        return ""
    return f"{int(event.get(done_key, 0)) + offset} of {int(total)}"


def interpret(event: dict) -> Update | None:
    """Turn one pipeline event into what a person should be told.

    Returns None for events that change nothing anyone is watching -- the
    caller keeps whatever it was showing.
    """
    kind = event.get("kind")

    # Finding a recording for a title, before there is anything to download.
    if kind == "matching":
        return Update(Stage.fetching, detail="Finding the song")

    if kind == "download_start":
        return Update(Stage.fetching, fraction=0.0)

    if kind == "download_progress":
        return Update(Stage.fetching, fraction=float(event.get("fraction", 0)))

    if kind == "download_done":
        title = event.get("title", "")
        return Update(
            Stage.fetching, fraction=1.0, title=title,
            note=f'Downloaded "{title}"' if title else "",
        )

    # ffmpeg, turning whatever was downloaded into what the models expect. It
    # reports no fraction, and inventing one is worse than a moving spinner.
    if kind == "decode_start":
        return Update(Stage.decoding)

    # A Mac handing the audio to the cloud, which will separate it.
    if kind == "handing_over":
        return Update(Stage.handing_over, detail=_megabytes(event))

    # Pulling a model onto the card. On a cold container this is most of the
    # wait, and it is the part of it with a countable end.
    if kind == "model_load":
        return Update(
            Stage.loading_models, detail=str(event.get("model", "")),
            fraction=_share(event),
        )

    # The model is up; what follows is the separation itself. Without this the
    # long part ran under the label of the step before it.
    if kind == "model_ready":
        return Update(
            Stage.separating, detail=None, fraction=_share(event),
        )

    # Inside one separation model, counted through its own chunk loop. The
    # fraction spans the whole separating step: which model, plus how far
    # through it.
    if kind == "inference_progress":
        total = float(event.get("total") or 1)
        index = float(event.get("index") or 0)
        within = float(event.get("fraction") or 0)
        return Update(
            Stage.separating, detail=None,
            fraction=max(0.0, min(1.0, (index + within) / total)),
        )

    if kind == "stage_start":
        return Update(
            Stage.separating, detail=event.get("title", ""),
            fraction=_share(event),
        )

    if kind == "analyse_start":
        return Update(Stage.measuring)

    if kind == "encode_start":
        return Update(Stage.packing, fraction=0.0)

    if kind == "encode_progress":
        return Update(
            Stage.packing, detail=_of(event, "done", offset=0),
            fraction=_share(event, "done"),
        )

    if kind == "uploading":
        return Update(Stage.uploading, detail=_megabytes(event))

    # Things worth writing down but not worth interrupting the display for.
    if kind == "stage_done":
        stems = ", ".join(event.get("stems", []))
        return Update(note=f'{event.get("stage")}: {stems}')

    if kind == "stage_skipped":
        return Update(note=f'Skipped {event.get("stage")}: {event.get("reason")}')

    if kind == "encode_failed":
        return Update(note=f'Could not encode {event.get("stem")}')

    if kind == "stem_missing":
        return Update(note=f'Warning: {event.get("file")} went missing')

    return None


def _megabytes(event: dict) -> str:
    size = event.get("megabytes")
    return f"{float(size):.0f} MB" if size else ""
