"""Every state anything in Musiclab can be in, named once.

Before this, the server had eight status values and eighteen phase strings
written as prose -- "Waiting for the fetch agent", "Getting the separation
models" -- and the worker had its own, differently worded set. Nothing
enumerated either, so no interface could reason about what it was showing: it
could only print the sentence it was handed and hope.

So the states live here, the labels live next to them, and both ends of the
system import the same file. The iOS app mirrors these strings in Swift; the
names are the contract between them, and the labels are free to be reworded
without anything breaking.
"""

from __future__ import annotations

from enum import Enum


class Stage(str, Enum):
    """Where one song is, from asked-for to listenable.

    The same vocabulary describes a job on the server and the machine working
    on it, because they are two views of one thing: a worker is "separating"
    exactly when the song it holds is.
    """

    queued = "queued"
    waiting_for_worker = "waiting_for_worker"
    fetching = "fetching"
    decoding = "decoding"
    loading_models = "loading_models"
    separating = "separating"
    packing = "packing"
    uploading = "uploading"
    needs_confirmation = "needs_confirmation"
    done = "done"
    failed = "failed"

    @property
    def label(self) -> str:
        return _LABELS[self]

    @property
    def is_terminal(self) -> bool:
        return self in (Stage.done, Stage.failed)

    @property
    def is_waiting(self) -> bool:
        """Nothing is happening yet, and nothing this end can do about it."""
        return self in (
            Stage.queued, Stage.waiting_for_worker, Stage.needs_confirmation
        )

    @property
    def determinate(self) -> bool:
        """Whether a fraction means anything here.

        Fetching knows its byte count and separating knows its stage count, so
        both can fill a bar honestly. Waiting for a Mac that may never appear
        cannot, and a bar that invents a number there is a lie that reads as
        progress.
        """
        return self in (
            Stage.fetching, Stage.loading_models, Stage.separating,
            Stage.packing, Stage.uploading,
        )


_LABELS: dict[Stage, str] = {
    Stage.queued: "Queued",
    Stage.waiting_for_worker: "Waiting for a Mac",
    Stage.fetching: "Downloading the audio",
    Stage.decoding: "Decoding the audio",
    Stage.loading_models: "Loading the models",
    Stage.separating: "Separating",
    Stage.packing: "Packing the stems",
    Stage.uploading: "Sending the stems back",
    Stage.needs_confirmation: "Waiting for you to confirm the match",
    Stage.done: "Done",
    Stage.failed: "Failed",
}


# What the old vocabulary called these, so jobs already in the store keep
# meaning something. A live system cannot be asked to forget its queue.
_LEGACY_STAGES = {
    "error": "failed",
    "awaiting_fetch": "waiting_for_worker",
    "running": "separating",
    "claimed": "separating",
    "fetching": "fetching",
}


def parse_stage(value: str | None) -> Stage | None:
    """A Stage from whatever the store happens to hold, or None."""
    if not value:
        return None
    try:
        return Stage(value)
    except ValueError:
        pass
    mapped = _LEGACY_STAGES.get(value)
    return Stage(mapped) if mapped else None


class WorkerState(str, Enum):
    """What a machine is, as distinct from what a song is.

    A worker is only ever one of these. `busy` defers to the job's Stage for
    the detail, so there is one place that knows the names of the steps.
    """

    offline = "offline"
    starting = "starting"
    downloading_models = "downloading_models"
    idle = "idle"
    busy = "busy"
    failed = "failed"

    @property
    def label(self) -> str:
        return _WORKER_LABELS[self]


_WORKER_LABELS: dict[WorkerState, str] = {
    WorkerState.offline: "Offline",
    WorkerState.starting: "Starting up",
    WorkerState.downloading_models: "Downloading the models",
    WorkerState.idle: "Idle, waiting for a song",
    WorkerState.busy: "Working",
    WorkerState.failed: "Stopped after an error",
}


class Failure(str, Enum):
    """Why a song stopped, in terms that suggest what to do about it.

    "Failed" on its own sends people to a log. Naming the kind means the app
    can say which of these it was, and say the one useful sentence about it.
    """

    downloader_outdated = "downloader_outdated"
    source_unavailable = "source_unavailable"
    bad_link = "bad_link"
    no_match = "no_match"
    fetch_failed = "fetch_failed"
    separation_failed = "separation_failed"
    upload_failed = "upload_failed"
    cancelled = "cancelled"
    unknown = "unknown"

    @property
    def label(self) -> str:
        return _FAILURE_LABELS[self][0]

    @property
    def remedy(self) -> str:
        """What the person reading this can actually do."""
        return _FAILURE_LABELS[self][1]

    @property
    def retryable(self) -> bool:
        """Whether handing this to another machine could go differently.

        A dropped connection could. A video that has been taken down, or a
        downloader YouTube has outgrown, could not: every worker would reach
        the same wall, and the song would circle the queue for ever while the
        person waiting was told only that it was waiting for a Mac.
        """
        return self in (
            Failure.fetch_failed, Failure.separation_failed,
            Failure.upload_failed, Failure.unknown,
        )

    @property
    def is_fixable(self) -> bool:
        """Whether the person reading this can do the thing that fixes it."""
        return self in (Failure.downloader_outdated, Failure.bad_link)


_FAILURE_LABELS: dict[Failure, tuple[str, str]] = {
    Failure.downloader_outdated: (
        "The downloader is out of date",
        "YouTube changed something yt-dlp no longer understands. Updating the "
        "Mac app fixes it; nothing is wrong with the song.",
    ),
    Failure.source_unavailable: (
        "The song could not be reached",
        "It may be private, removed, or blocked where the Mac is.",
    ),
    Failure.bad_link: (
        "That link does not point at a song",
        "Check it opens in a browser, then paste it again.",
    ),
    Failure.no_match: (
        "No recording matched",
        "Nothing close enough was found. Try pasting a link instead.",
    ),
    Failure.fetch_failed: (
        "The download did not finish",
        "Usually the network. Queue it again.",
    ),
    Failure.separation_failed: (
        "Separating did not finish",
        "The audio reached the separator and it stopped. Queue it again.",
    ),
    Failure.upload_failed: (
        "The stems did not arrive",
        "They were made, but the handover failed. Queue it again.",
    ),
    Failure.cancelled: ("Cancelled", "You stopped this one."),
    Failure.unknown: ("Something went wrong", "Queue it again."),
}


# Saying "your downloader is out of date" when it is not is worse than saying
# nothing: it sends someone to reinstall a 340 MB app over a dropped
# connection. So the signs have to be ones yt-dlp only produces when the
# extractor itself has actually given up.
#
# "nsig extraction failed" is deliberately not among them. yt-dlp prints it as
# a warning and usually downloads anyway, so on its own it is evidence of
# nothing; it counts only alongside a failure to extract.
_OUTDATED_SIGNS = (
    "please report this issue on https://github.com/yt-dlp",
    "please report this issue on  https://github.com/yt-dlp",
    "unable to extract yt initial data",
    "unable to extract player",
    "unable to extract signature",
    "unable to extract nsig",
)

# Anti-bot challenges. Updating often does help, but the advice is different
# enough -- wait, or sign the downloader in -- to be worth its own answer.
_BLOCKED_SIGNS = (
    "confirm you're not a bot",
    "confirm you are not a bot",
    "sign in to confirm",
)

_BAD_LINK_SIGNS = (
    "incomplete youtube id",
    "looks truncated",
    "is not a valid url",
    "unsupported url",
)

_UNAVAILABLE_SIGNS = (
    "video unavailable",
    "private video",
    "has been removed",
    "is not available",
    "age-restricted",
    "members-only",
    "copyright",
)


def classify(error: str | BaseException) -> Failure:
    """Work out which kind of failure a message describes.

    Guessing from strings is unpleasant, and it is what there is: yt-dlp
    reports everything as one exception type. The alternative -- calling all of
    them "something went wrong" -- hides the single failure a person can
    actually fix, which is an out-of-date downloader.
    """
    text = str(error).lower()
    if not text:
        return Failure.unknown
    if any(sign in text for sign in _BAD_LINK_SIGNS):
        return Failure.bad_link
    if any(sign in text for sign in _OUTDATED_SIGNS):
        return Failure.downloader_outdated
    if any(sign in text for sign in _BLOCKED_SIGNS):
        return Failure.source_unavailable
    if any(sign in text for sign in _UNAVAILABLE_SIGNS):
        return Failure.source_unavailable
    if "no match" in text:
        return Failure.no_match
    return Failure.unknown
