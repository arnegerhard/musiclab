"""Paths, defaults, and the definition of the separation cascade."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _state_root() -> Path:
    """Where downloaded models and finished songs belong.

    Next to the source in a checkout, which is convenient while developing. But
    inside a packaged .app that would mean writing into the bundle: it breaks
    the code signature, may not be permitted at all under /Applications, and is
    thrown away by the next update. So a bundle keeps its state beside the
    user's other application data instead.
    """
    if ".app/Contents/" in str(ROOT):
        return Path.home() / "Library" / "Application Support" / "Musiclab"
    return ROOT


STATE_DIR = _state_root()
OUT_DIR = Path(os.environ.get("STEMS_OUT_DIR", STATE_DIR / "out"))
MODEL_DIR = Path(os.environ.get("STEMS_MODEL_DIR", STATE_DIR / "models"))

# The stem every stage reads from when it works on the untouched mixdown.
SOURCE_INPUT = "__input__"


@dataclass(frozen=True)
class AudioFormat:
    """How finished stems are stored on disk."""

    key: str
    extension: str
    codec_args: tuple[str, ...]
    lossless: bool
    note: str


# Measured on a 14-stem, 5:36 track: WAV 792 MB, FLAC 200 MB, MP3-320 189 MB,
# AAC-256 137 MB, AAC-192 106 MB. MP3 at 320k costs the same bytes as FLAC and
# throws information away, so FLAC is the default.
FORMATS = {
    "flac": AudioFormat(
        key="flac",
        extension=".flac",
        codec_args=("-c:a", "flac", "-compression_level", "8"),
        lossless=True,
        note="Lossless, about a quarter the size of WAV. Safe for a DAW.",
    ),
    "m4a": AudioFormat(
        key="m4a",
        extension=".m4a",
        codec_args=("-c:a", "aac", "-b:a", "256k"),
        lossless=False,
        note="AAC 256k. Roughly six times smaller than WAV.",
    ),
    "m4a-compact": AudioFormat(
        key="m4a-compact",
        extension=".m4a",
        codec_args=("-c:a", "aac", "-b:a", "128k"),
        lossless=False,
        note="AAC 128k. About the size of an ordinary MP3, per stem.",
    ),
    "m4a-small": AudioFormat(
        key="m4a-small",
        extension=".m4a",
        codec_args=("-c:a", "aac", "-b:a", "192k"),
        lossless=False,
        note="AAC 192k. A little more room than the default.",
    ),
    "mp3": AudioFormat(
        key="mp3",
        extension=".mp3",
        codec_args=("-c:a", "libmp3lame", "-b:a", "320k"),
        lossless=False,
        note="MP3 320k, for tools that accept nothing else.",
    ),
    "wav": AudioFormat(
        key="wav",
        extension=".wav",
        codec_args=("-c:a", "pcm_s16le"),
        lossless=True,
        note="Uncompressed. Large.",
    ),
}

# Lossless was costing a hundred and sixty megabytes of stems for a
# five-minute song. These are already-separated parts listened to as points in
# a room, not masters; a stem now weighs about what an MP3 of the whole song
# does. Ask for flac explicitly if a DAW is the destination.
DEFAULT_FORMAT = "m4a-compact"


@dataclass(frozen=True)
class Stage:
    """One separation pass: feed it a stem, get finer stems back.

    Model files get renamed upstream more often than you would hope, so a stage
    names the model by keyword and resolves it against the installed registry
    at runtime (see stems.models) instead of pinning a filename.
    """

    key: str
    title: str
    # Known-good model filenames, tried in order before the keyword search.
    preferred: tuple[str, ...]
    # Ordered fallbacks; each is a keyword set matched against model filenames.
    model_keywords: tuple[tuple[str, ...], ...]
    source: str
    # Substring of the model's own output label -> the stem name we publish.
    rename: dict[str, str] = field(default_factory=dict)
    # Stages past the base pass are opt-in and skipped if the model is missing.
    optional: bool = False
    note: str = ""


BASE_STAGE = Stage(
    key="base",
    title="Six-way split",
    preferred=("htdemucs_6s.yaml",),
    model_keywords=(("htdemucs_6s",), ("htdemucs_ft",), ("htdemucs",)),
    source=SOURCE_INPUT,
    rename={
        "vocals": "vocals",
        "drums": "drums",
        "bass": "bass",
        "guitar": "guitar",
        "piano": "piano",
        "other": "other",
    },
    note="Vocals, drums, bass, guitar, piano, and everything else.",
)

VOCAL_STAGE = Stage(
    key="vocals",
    title="Lead vs. backing vocals",
    preferred=(
        "mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt",
        "mel_band_roformer_karaoke_becruily.ckpt",
        "UVR_MDXNET_KARA_2.onnx",
    ),
    model_keywords=(
        ("mel_band_roformer", "karaoke"),
        ("karaoke",),
        ("kara",),
    ),
    source="vocals",
    # Karaoke models emit the lead on the "vocals" side and everything stacked
    # behind it on the "instrumental" side.
    rename={
        "instrumental": "backing_vocals",
        "backing": "backing_vocals",
        "vocals": "lead_vocal",
    },
    optional=True,
    note="Splits the vocal stem into the lead line and the stacked harmonies.",
)

DRUM_STAGE = Stage(
    key="drums",
    title="Drum kit pieces",
    preferred=("MDX23C-DrumSep-aufr33-jarredou.ckpt",),
    model_keywords=(("drumsep",), ("drum", "sep"), ("mdx23c", "drum")),
    source="drums",
    # The kit model labels the hats "HH"; the rest of its names read fine.
    rename={"hh": "hihat"},
    optional=True,
    note="Splits the drum stem into kick, snare, toms, and cymbals.",
)

ALL_STAGES = (BASE_STAGE, VOCAL_STAGE, DRUM_STAGE)
STAGES_BY_KEY = {s.key: s for s in ALL_STAGES}

# Display order for the mixer, so a track list reads like a session.
STEM_ORDER = [
    "lead_vocal",
    "backing_vocals",
    "vocals",
    "guitar",
    "piano",
    "bass",
    "kick",
    "snare",
    "toms",
    "hh",
    "hihat",
    "ride",
    "crash",
    "cymbals",
    "drums",
    "other",
]


def stem_sort_key(name: str) -> tuple[int, str]:
    try:
        return (STEM_ORDER.index(name), name)
    except ValueError:
        return (len(STEM_ORDER), name)
