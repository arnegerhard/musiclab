# stems

Paste a YouTube link, get the song back as separate tracks you can solo, mute,
and download — as a local web app or a CLI.

## What you actually get

The separation runs as a cascade: split the mix, then split the splits.

```
mix
├── vocals ──────┬── lead_vocal
│                └── backing_vocals      (all stacked harmonies together)
├── drums ───────┬── kick
│                ├── snare
│                ├── toms
│                ├── hihat
│                ├── ride
│                └── crash
├── bass
├── guitar                               (all guitar layers together)
├── piano
└── other                                (brass, strings, synths, everything else)
```

Fourteen tracks. Every parent stem is kept alongside its children, so you can
A/B a split against the combined version, or fall back to it when a split
sounds worse than the whole.

### What this cannot do

Being straight about the limits, because the request asked for more than the
state of the art delivers:

- **Each harmony as its own track.** Not possible. Backing vocals come out as
  one stacked stem. No released model separates individual harmony lines —
  they share timbre and pitch space, which is exactly what these models key on.
- **Each guitar layer separately.** Not possible. All the guitars land in one
  `guitar` stem, layered as they were in the mix.
- **Brass apart from strings.** Not possible. There is no brass or strings
  model; both end up inside `other`.

Everything in the tree above *is* real and works. Anything finer is a research
problem, not a configuration flag.

Separation is also lossy. Stems carry bleed from neighbouring instruments and
some smearing artifacts, and quiet parts are hardest. The manifest records a
reconstruction error — how much of the original survives summing the leaf stems
back together — as a sanity check.

## Setup

Needs `ffmpeg` and `uv`.

```bash
brew install ffmpeg
```

```bash
uv venv --python 3.12 && uv pip install -e .
```

Models (about 700 MB total) download themselves on first run and are cached in
`models/`.

## Use it

The web app — paste a URL, watch it work, then mix in the browser:

```bash
.venv/bin/python -m stems.cli --serve
```

Then open http://127.0.0.1:8000.

Or the CLI:

```bash
.venv/bin/python -m stems.cli "https://www.youtube.com/watch?v=..."
```

Skip the second-pass splits when you only want the six base stems:

```bash
.venv/bin/python -m stems.cli --no-vocal-split --no-drum-split "https://youtu.be/..."
```

## Output

Each track gets a folder under `out/`:

```
out/cool-rock-TwsWXrMS7OM/
├── source.flac         the downloaded mix
├── manifest.json       stem tree, peak/RMS levels, timings
├── stems/              the actual output, in your chosen format
│   ├── lead_vocal.flac
│   ├── backing_vocals.flac
│   └── ...
├── previews/           stereo AAC, only for the browser mixer
└── spatial/            mono AAC, only for the iOS app
```

All stems are 44.1 kHz stereo, the same length as the source, so they line up
on a timeline if you drag them into a DAW.

### Storage format

Separation itself always produces WAV, and levels are measured on that WAV
before anything is encoded. What lands on disk is up to you:

```bash
.venv/bin/python -m stems.cli --formats
```

| Format | 14 stems, 5:36 | vs WAV | |
|---|---|---|---|
| `wav` | 792 MB | — | uncompressed |
| `flac` **(default)** | 200 MB | **4.0x** | lossless |
| `mp3` (320k) | 189 MB | 4.2x | lossy |
| `m4a` (AAC 256k) | 137 MB | 5.8x | lossy |
| `m4a-small` (AAC 192k) | 106 MB | 7.5x | lossy |

FLAC is the default because MP3 at 320 kbps costs the same bytes and throws
information away — and since separation artifacts and lossy artifacts compound,
stems you might later drag into a DAW are worth keeping intact.

```bash
.venv/bin/python -m stems.cli --format m4a "https://youtu.be/..."
```

Already have a library in another format? Convert it in place:

```bash
.venv/bin/python -m stems.cli --recompress --format flac
```

### Why the extra copies

The browser mixer plays fourteen tracks at once, which is 200 MB of FLAC for a
3.5-minute song — enough to wedge a tab. So a lossless master also gets a
128 kbps stereo AAC preview to stream. Choose a lossy master and that tier
disappears: the master is small enough to stream itself, and `previews/` is
not written at all.

`spatial/` is always written, and is not about size: `AVAudioEnvironmentNode`
only spatialises **mono** inputs, so the iOS app needs a mono asset regardless
of what the master is.

Expect roughly 2.5x the track length to process on an Apple-silicon laptop: a
3.5-minute song took about 8.5 minutes across all three stages, or 20 seconds
for a 55-second clip with only the base split.

## How it fits together

| File | Role |
|---|---|
| `stems/download.py` | yt-dlp → 44.1 kHz stereo WAV |
| `stems/config.py` | the cascade: which stage splits what |
| `stems/models.py` | resolves stage models against the installed registry |
| `stems/separate.py` | runs the stages, names and files the outputs |
| `stems/pipeline.py` | orchestration, levels, manifest |
| `stems/server.py` | job queue + JSON API |
| `stems/web/index.html` | the mixer |

The mixer streams through `<audio>` elements rather than decoded Web Audio
buffers — fourteen decoded stems of an 8-minute song is ~2.4 GB of PCM. The
trade-off is that elements drift apart, so playback pre-rolls every element to
the same position before starting and a timer nudges stragglers back.

Stages name their model by keyword rather than pinning a filename, because
upstream renames checkpoints between releases; `models.py` tries known-good
names first and falls back to a keyword search.

Models used: `htdemucs_6s` for the six-way split,
`mel_band_roformer_karaoke` for lead vs. backing, and `MDX23C-DrumSep` for the
kit. All are downloaded via [`audio-separator`](https://github.com/nomadkaraoke/python-audio-separator).

## Reaching the server from anywhere

Bonjour only works on the local network, so it is for local development only.
Anywhere else it is off:

```bash
.venv/bin/python -m stems.cli --serve --no-bonjour      # or STEMS_BONJOUR=0
```

### Where the app looks

The app picks a server by how the build reached the device, and always falls
back to the deployed one:

| Build | First choice | Fallback |
|---|---|---|
| Simulator | the Mac, via Bonjour | deployed server |
| Xcode → phone | the Mac, via Bonjour | deployed server |
| TestFlight | deployed server | — |
| App Store | deployed server | — |

TestFlight and App Store builds never browse the local network: they are on
somebody else's phone, on a network where Bonjour cannot reach your Mac, and
browsing would trigger a local-network permission prompt for no reason.

The deployed address is a build setting, so nothing is hardcoded in source:

```bash
xcodebuild ... MUSICLAB_CLOUD_URL=https://stems.jetsons.info \
               MUSICLAB_CLOUD_TOKEN=<the STEMS_TOKEN value>
```

A development build can be made to behave like a shipped one, which is the only
way to exercise that path before actually shipping:

```bash
xcrun simctl launch <udid> info.jetsons.musiclab --args -distribution appStore
```

### Deploying: Cloudflare Tunnel

**Separation cannot run on Cloudflare.** Workers execute JavaScript and WASM,
not PyTorch. Containers top out at 4 vCPU and 12 GiB with no GPU, sleep when
idle, and would need the ~700 MB of model weights on every cold start — for
work that already runs at 2.5x realtime on the Mac.

So the Mac keeps doing the work, and Cloudflare Tunnel gives it a public
hostname. `cloudflared` dials out to Cloudflare, so no port is forwarded and no
inbound firewall rule is needed.

```bash
brew install cloudflared
cloudflared tunnel login                                  # pick jetsons.info
cloudflared tunnel create musiclab
cloudflared tunnel route dns musiclab stems.jetsons.info
```

`~/.cloudflared/config.yml`:

```yaml
tunnel: <the UUID that `create` printed>
credentials-file: /Users/arne/.cloudflared/<UUID>.json
ingress:
  - hostname: stems.jetsons.info
    service: http://localhost:8000
  - service: http_status:404
```

Then run it, with a token set so the world cannot use your Mac as a
free transcoding service:

```bash
STEMS_TOKEN=$(openssl rand -hex 24) .venv/bin/python -m stems.cli --serve --no-bonjour
cloudflared tunnel run musiclab
```

`sudo cloudflared service install` keeps the tunnel up across reboots.

### What actually changes in Cloudflare

Mostly nothing by hand — `tunnel route dns` writes the DNS record for you:

| Where | What | Why |
|---|---|---|
| **DNS** | proxied `CNAME` `stems` → `<UUID>.cfargotunnel.com` | created by `route dns`; leave the orange cloud on |
| **SSL/TLS** | mode **Full** | Cloudflare terminates TLS; the tunnel is already encrypted |
| **Cache rules** | bypass cache for `/api/*` | manifests and job status change; stale ones break the app |
| **Cache rules** | cache `/files/*` | stems never change once written, so serve them from the edge |
| **Zero Trust → Tunnels** | the tunnel appears here | where you check it is healthy |

Two Cloudflare limits worth knowing: the proxy read timeout is **125 seconds**,
which is fine because separation is queued and polled rather than held open on
one request; and audio seeking relies on range requests, which the proxy passes
through.

### If you want the Mac to be off

This design needs the Mac awake. Making playback survive a sleeping Mac is a
different job: sync `out/` to **R2** and put a Worker in front to serve the
library and files. Separation would still need the Mac, or a GPU host — R2 and
a Worker only remove the Mac from the *playback* path.

## Running separation on the device

`export/` converts `htdemucs_6s` to a Core ML package, so the six base stems
can be produced on an iPhone with no server at all.

```bash
.venv/bin/python export/to_coreml.py build/htdemucs_6s.mlpackage
.venv/bin/python export/verify.py build/htdemucs_6s.mlpackage <some>/source.flac
```

Measured on an M4, 7.8 s segment, fp16:

| | |
|---|---|
| speed | **18.8x realtime** (0.41 s per 7.8 s segment) |
| accuracy vs PyTorch | 57.8 dB SNR overall, error at **-84 dBFS** |
| package size | 171 MB |

### What the conversion needed

Core ML will not take htdemucs as it stands, for four separate reasons:

1. **No complex dtype.** Its type domain is `fp16, fp32, int8/16/32,
   uint8/16, bool`. It can *build* a complex value and run `stft` and `irfft`,
   but it cannot slice or pad one -- and demucs does both. There is no `istft`
   and no `view_as_complex` at all.

   With `cac=True` the network already works on real tensors: the complex
   spectrogram exists only to be unpacked by `view_as_real`, and `_mask`
   ignores it outright. So `export/htdemucs_real.py` carries `(real, imag)` as
   a trailing axis from the moment the STFT produces it, and
   `export/spectral.py` writes the inverse transform by hand.

2. **Rank 5 maximum.** Adding that trailing axis makes the mask rank 6, so
   sources and channels stay merged until the axis is gone.

3. **Fused attention.** `nn.MultiheadAttention` takes a fast path in eval mode
   that traces to one `_native_multi_head_attention` the converter does not
   implement. `torch.backends.mha.set_fastpath_enabled(False)` makes it trace
   as ordinary matmul and softmax.

4. **A converter quirk.** Shape arithmetic arrives as a one-element array
   where its int cast wants a scalar; `to_coreml.py` unwraps it.

The rewrite is numerically exact: **8.9e-08** maximum difference against the
original PyTorch model, which is float32 rounding.

### The overlap-add trap

The first working version ran at **0.05x realtime** -- 156 seconds for one 7.8
second segment. The cause was the inverse transform: expressing overlap-add as
a transposed convolution with an identity kernel is correct and one line, but
it costs O(n_fft^2) per frame, about 5.7 GMAC per segment.

Because the hop divides `n_fft` exactly, the frames split into four
interleaved lanes whose members never overlap, so each lane is a reshape laid
end to end and the lanes are summed at their offsets. Same result, O(n_fft)
per frame, **380x faster**.

### What is not on the device

- **The two refinement stages.** Lead/backing vocals and the drum kit split
  need another 1.3 GB of weights and the same surgery each. The six base stems
  are the 52 MB one.
- **YouTube.** Not a technical limit: App Store guideline 5.2.3 names YouTube
  directly, and TestFlight goes through the same review. On-device separation
  is worth pairing with local file import rather than downloads.

## Playlists

The app reads playlists from **Apple Music** and **Spotify** so you can pick
songs there rather than pasting URLs.

**Neither service will give you audio, and that is not a limitation you can
engineer around.** Spotify never exposes decoded audio to third-party apps; the
Web Playback SDK and iOS SDK both play through their own DRM'd player. Apple
Music streaming is FairPlay-protected — `assetURL` is nil and
`hasProtectedAsset` is true. Separation needs PCM, so neither can supply it.

Playlists are therefore a **choosing surface**. Pick songs there, and the Mac
matches each one to a YouTube upload and separates that. What you get is a
recording of the song, not necessarily the master your service would stream.

### Matching

Match quality is the whole game: the wrong hit means separating a live cut or
a cover, and you only find out when it sounds wrong. `stems/match.py` scores
candidates on

- **duration** — the strongest signal, since a cover or live version is rarely
  within a couple of seconds of the studio take
- **channel** — `"Artist - Topic"` is label-delivered audio and scores highest;
  an exact artist channel next. A channel that merely *contains* the artist
  ("This Is Queen") is treated as a fan upload
- **title overlap**, after stripping "(2006 Remaster)", "[Official Audio]" and
  similar noise
- **penalties** for `live`, `cover`, `karaoke`, `nightcore`, `sped up`,
  `reaction` and friends — unless you asked for them

Anything scoring below 70 stops and asks rather than guessing:

```
Yesterday   needs_confirmation   Confirm the match
            Unsure: "Yesterday (Remastered 2009)" scored 36.0
```

The app shows the candidates with durations and the reasons behind each score,
and separation only starts once you pick one.

### Setup

Apple Music needs nothing beyond granting library access on first use. Spotify
needs a client ID from your own dashboard at
[developer.spotify.com](https://developer.spotify.com/dashboard), with
`musiclab://spotify-callback` added as a redirect URI. Sign-in uses Authorisation
Code with PKCE — no client secret on the phone — and the refresh token goes in
the keychain.

### Endpoints

| Endpoint | Purpose |
|---|---|
| `POST /api/match` | preview what a track would match to |
| `POST /api/batch` | queue a playlist selection |
| `GET /api/batch/{id}` | per-track progress |
| `POST /api/jobs/{id}/confirm` | pick a recording for an uncertain match |

Jobs run one at a time, and each finished track records `matched_from` and
`playlist_track` in its manifest, so you can always see what was actually
separated.

## Musiclab: the iOS app

`ios/` is **Musiclab**, a SwiftUI app that puts each stem at a point in a virtual room and
renders it binaurally, so a song arrives as a band playing around you rather
than as a stereo image between your ears.

The Mac keeps doing the separation — Demucs and the roformer models are
PyTorch, and converting them to CoreML is its own project — so the phone is a
client. The server advertises itself over Bonjour; the app finds it, downloads
the mono stems, and plays them locally.

```bash
cd ios && xcodegen generate && open Musiclab.xcodeproj
```

Set your signing team in Xcode, then run. On the Mac, start the server — note
the `cd` back to the repo root, since the line above leaves you in `ios/`:

```bash
cd /Users/arne/Code/stems && .venv/bin/python -m stems.cli --serve
```

### How it sounds like a room

Distance is heard as the ratio of dry to reverberant sound far more than as
loudness — drop only the volume and a stem sounds *quieter*, not *farther*. So
moving a source updates three things together:

| Distance drives | Via | Perceptual job |
|---|---|---|
| Direct gain | environment node's inverse rolloff | Loudness |
| Reverb send | `reverbBlend` per player | **Distance** |
| High-frequency loss | `obstruction` per player | Air absorption |

`obstruction` rather than `occlusion` on purpose: it filters the direct path
while leaving the reverb send alone, which is the "far away" timbre. Occlusion
would duck the reverb too and fight the distance model's own attenuation.

### Head tracking

With AirPods (Pro / Max / 3rd gen or later), `CMHeadphoneMotionManager` feeds
head orientation into the listener transform, so turning your head leaves the
band where it stands. This is what sells the illusion — without it, sources
tend to collapse inside your head and front/back gets confused. On other
headphones, or in the simulator, a rotation slider stands in.

### The audio graph

```
14 x AVAudioPlayerNode (mono) --> AVAudioEnvironmentNode --> output
        3D position, reverb,          listener transform,
        obstruction, volume            room reverb, HRTF
```

Nothing may sit between a player and the environment node: `AVAudioUnitEQ`
does not adopt `AVAudioMixing`, so inserting one silently costs the source its
3D position. Every per-source effect therefore has to be a property the
player itself exposes.

Stems are downloaded rather than streamed, because `AVAudioFile` needs local
files — and having them local is what allows all fourteen players to be
scheduled against one shared `AVAudioTime`. That makes them **sample-locked**,
which the browser mixer never managed; it needed a pre-roll hack to get within
~12 ms.

### App icon

`ios/musiclab-icon.png` is the source artwork. It is not used directly: iOS
masks every icon with its own superellipse and shows no transparency, so an
icon that already has rounded corners and a black surround comes out as a dark
frame around a smaller, double-rounded icon.

```bash
cd ios && ../.venv/bin/python make-icon.py musiclab-icon.png
```

That crops to the artwork, repaints the black surround and its anti-aliased
rim in the frame's own colour, and writes an opaque 1024x1024 PNG into
`Musiclab/Assets.xcassets/AppIcon.appiconset/`. Re-run it after replacing the
artwork, then rebuild.

### Known rough edges

- **Head tracking is unverified on hardware.** The simulator reports no
  motion, so it has only been exercised through the manual fallback. If the
  room turns the wrong way when you turn your head, flip `yawSign` in
  `HeadTracker.swift` — CoreMotion's head frame and the audio environment's
  listener frame disagree about handedness on some hardware.
- Discovery occasionally needs the app relaunched if the server starts later.
- Scenes save to the server per track, but there is no way to keep more than
  one arrangement per song yet.

## Note

Downloading YouTube audio is against YouTube's Terms of Service, and separated
stems are derivative works. Fine for practising along with, transcribing, or
studying a mix you own; the redistribution question is yours to answer.
