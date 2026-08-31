"""Find the YouTube upload that corresponds to a track from a playlist.

Playlist services hand over metadata but never audio, so a track picked in the
app has to be matched to something downloadable. Match quality is the whole
game here: the wrong hit means separating a live cut, a cover, or a sped-up
re-upload, and the user only finds out when it sounds wrong.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# Words that mark an upload as not the studio recording we were asked for.
# Only penalised when the query itself did not ask for them.
VARIANT_PENALTIES = {
    "live": 30, "concert": 25, "cover": 35, "karaoke": 40, "instrumental": 30,
    "remix": 30, "reaction": 45, "review": 35, "tutorial": 40, "lesson": 40,
    "sped up": 35, "slowed": 35, "nightcore": 40, "8d audio": 35,
    "loop": 25, "mashup": 30, "tribute": 30, "in the style of": 40,
    "backing track": 35, "acapella": 30, "a capella": 30, "demo": 15,
    "rehearsal": 25, "snippet": 30, "teaser": 30, "trailer": 30,
}

# Noise in track titles that should not count against a match.
TITLE_NOISE = re.compile(
    r"\((?:feat|ft|with)\.?[^)]*\)|\[[^\]]*\]|"
    r"\b(?:\d{4}\s+)?(?:remaster(?:ed)?|deluxe|mono|stereo|bonus track|album version|"
    r"single version|radio edit|\d{4} mix)\b",
    re.IGNORECASE,
)


def normalise(text: str) -> str:
    text = TITLE_NOISE.sub(" ", text or "")
    text = re.sub(r"[^\w\s]", " ", text.lower())
    return re.sub(r"\s+", " ", text).strip()


def _tokens(text: str) -> set[str]:
    return {t for t in normalise(text).split() if len(t) > 1}


def _overlap(wanted: set[str], found: set[str]) -> float:
    if not wanted:
        return 0.0
    return len(wanted & found) / len(wanted)


@dataclass
class Candidate:
    video_id: str
    title: str
    channel: str
    duration: float | None
    score: float = 0.0
    reasons: list[str] = field(default_factory=list)

    @property
    def url(self) -> str:
        return f"https://www.youtube.com/watch?v={self.video_id}"

    @property
    def confident(self) -> bool:
        """High enough to separate without asking the user to confirm."""
        return self.score >= 70


def score_candidate(
    candidate: Candidate, title: str, artist: str, duration: float | None
) -> Candidate:
    score = 0.0
    reasons: list[str] = []

    found_title = _tokens(candidate.title)
    found_channel = _tokens(candidate.channel)
    wanted_title = _tokens(title)
    wanted_artist = _tokens(artist)

    # Duration is the single most reliable signal: a cover or a live cut is
    # rarely within a couple of seconds of the studio take.
    if duration and candidate.duration:
        delta = abs(candidate.duration - duration)
        if delta <= 2:
            score += 45; reasons.append("duration matches")
        elif delta <= 5:
            score += 32; reasons.append("duration close")
        elif delta <= 12:
            score += 12
        elif delta > 25:
            score -= 40; reasons.append(f"duration off by {delta:.0f}s")
        else:
            score -= 10
    elif duration:
        score -= 5

    title_hit = _overlap(wanted_title, found_title)
    score += 30 * title_hit
    if title_hit >= 0.9:
        reasons.append("title matches")

    # "Artist - Topic" channels are label-delivered audio rather than a fan
    # re-upload, so they are usually the correct master.
    channel = (candidate.channel or "").strip()
    # An exact channel name is the artist's own; a channel that merely contains
    # the artist ("This Is Queen") is a fan upload and should not score as if
    # it were official.
    channel_extra = found_channel - wanted_artist - {"official", "vevo", "music", "band"}
    exact_channel = bool(wanted_artist) and wanted_artist <= found_channel and not channel_extra

    if channel.lower().endswith("- topic"):
        score += 35; reasons.append("official label audio")
    elif exact_channel:
        score += 28; reasons.append("artist's channel")
    elif wanted_artist and _overlap(wanted_artist, found_channel) >= 0.6:
        score += 10; reasons.append("fan channel")

    artist_hit = _overlap(wanted_artist, found_title | found_channel)
    score += 18 * artist_hit
    if artist_hit < 0.34 and wanted_artist:
        score -= 15; reasons.append("artist not mentioned")

    haystack = f"{candidate.title} {candidate.channel}".lower()
    asked_for = f"{title} {artist}".lower()
    for word, penalty in VARIANT_PENALTIES.items():
        if word in haystack and word not in asked_for:
            score -= penalty
            reasons.append(f"looks like a {word}")

    if "official" in haystack and "official" not in asked_for:
        score += 8

    candidate.score = round(score, 1)
    candidate.reasons = reasons
    return candidate


def search(
    title: str, artist: str = "", duration: float | None = None, limit: int = 8
) -> list[Candidate]:
    """Search YouTube and return candidates, best first."""
    import yt_dlp

    query = " ".join(part for part in (artist, title) if part).strip()
    options = {
        "quiet": True, "no_warnings": True, "skip_download": True,
        "extract_flat": "in_playlist", "socket_timeout": 20, "ignoreerrors": True,
    }
    with yt_dlp.YoutubeDL(options) as ydl:
        result = ydl.extract_info(f"ytsearch{limit}:{query}", download=False)

    candidates = []
    for entry in (result or {}).get("entries") or []:
        if not entry or not entry.get("id"):
            continue
        candidates.append(
            score_candidate(
                Candidate(
                    video_id=entry["id"],
                    title=entry.get("title") or "",
                    channel=entry.get("channel") or entry.get("uploader") or "",
                    duration=entry.get("duration"),
                ),
                title, artist, duration,
            )
        )
    return sorted(candidates, key=lambda c: c.score, reverse=True)


def best(title: str, artist: str = "", duration: float | None = None) -> Candidate | None:
    results = search(title, artist, duration)
    return results[0] if results else None
