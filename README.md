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

### The mono sidecar

`spatial/` holds a mono AAC copy of every stem. This is not a size saving:
`AVAudioEnvironmentNode` only spatialises **mono** inputs -- a stereo source is
passed through unpositioned -- so the app needs a mono asset whatever the
master format is.

There used to be a third `previews/` tier of stereo AAC for a browser mixer.
That mixer is gone, and so is the tier.

## Accounts

Every song belongs to an account, and accounts cannot see each other's.

```bash
.venv/bin/python -m stems.cli --add-user you@example.com   # prompts for a password
.venv/bin/python -m stems.cli --list-users
.venv/bin/python -m stems.cli --claim you@example.com      # adopt pre-account tracks
```

Or just create the account from the app's sign-in screen.

### Signing in

- **Apple.** The app sends Apple's identity token; the server verifies its
  signature against Apple's published keys and checks the audience is this
  bundle id, so a token minted for another app will not work. If someone signed
  up by email and later uses Apple with the same address, the accounts are
  linked rather than duplicated.
- **Email and password.** Hashed with `scrypt` from the standard library --
  memory-hard, per-password salt, no extra dependency.
- **Sessions** are random bearer tokens; only their SHA-256 is stored, so a
  copy of the database does not hand over live sessions. The app keeps its
  token in the keychain.

### Password reset

`POST /api/auth/reset/request` emails a six-digit code, valid 15 minutes,
single use, five attempts. Configure mail with `SMTP_HOST`, `SMTP_PORT`,
`SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`. **Without SMTP the code is printed
to the server console**, so a one-person server is never locked out.

Requesting a reset answers the same whether or not the address has an account,
and a failed sign-in says "wrong email or password" either way, so neither can
be used to discover who has an account.

### How songs are separated per user

Tracks live at `out/<user id>/<slug>/`, so accounts are separated on disk
rather than merely filtered in a query.

The blanket `StaticFiles` mount over the whole output directory is gone: with
accounts it would have let any signed-in user read any other's songs by
guessing a path. `/files/{slug}/{path}` now resolves inside the caller's own
tree, and **the URL carries no user id at all** -- it comes from the session,
so it cannot be pointed elsewhere. Paths are resolved before the containment
check, which is what stops `..` and symlinks. Range requests still work, so
audio still seeks.

### Do you need a database?

Yes, and it is SQLite -- a single file, no server, in the standard library.
The reason is not scale: the separation worker writes from a background thread
while request handlers read and write on the event loop, and JSON files would
need their own locking and could still tear a write.

## Reaching the server from anywhere

Bonjour only works on the local network, so it is for local development only.
Anywhere else it is off:

```bash
.venv/bin/python -m stems.cli --serve --no-bonjour      # or STEMS_BONJOUR=0
```

### Where the app looks

Always the Mac on this network first, whatever the build -- it is faster, it is
free, and it is where songs are separated. The deployed host is the fallback
for when the Mac is not running or not on this network.

A remembered address is re-checked at launch and whenever the app returns to
the foreground, so a Mac that went to sleep or changed address does not strand
the app. If the server disappears **during** a separation, the progress screen
notices after three missed polls and says so, rather than spinning on a job
that is no longer running.

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

### Running it on a GPU instead

`modal_app.py` deploys the same pipeline to Modal, where separation runs on an
A100 rather than the Mac's GPU.

```bash
uv pip install modal
modal token new                        # once, opens a browser
modal deploy modal_app.py
modal run modal_app.py --email you@example.com --password ...
```

Then point the app at the printed `https://….modal.run` URL.

**The library moves with the compute.** A finished song is ~150 MB of stems,
and shipping that back to the Mac over a domestic uplink would cost back
everything the GPU won, so the volume holding the library lives beside the
worker.

Two containers, because they want different hardware:

| | Hardware | Why |
|---|---|---|
| `web` | CPU, one container | Serves the API and owns the SQLite file |
| `worker` | A100, up to ten | One song each, so a playlist separates in parallel |

That is the real speed win. A single song is bounded by the model; a
twenty-song playlist used to run one at a time and now does not.

Since those are separate containers, job state moved out of process memory into
a `modal.Dict`, and the volume is committed by the worker and reloaded by the
web app -- `stems/jobs.py` holds both seams, and locally both are no-ops.

Model weights are baked into the image at build time. Downloading 1.3 GB on
first request instead would put a minute of cold start in front of a job that
takes about a minute.

### Measured, and not

The stage timings below are measured on an M4; the GPU figures are not. Modal
was written and type-checked but never deployed, because deploying needs a
`modal token new` that only you can run.

| Stage | Share of runtime on M4 |
|---|---|
| Demucs 6-stem | 11% |
| **Mel-Band Roformer (lead/backing)** | **65%** |
| MDX23C (drum kit) | 24% |

The vocal split dominates, so it is what any GPU has to be fast at.

### If you want the Mac to be off

This design needs the Mac awake. Making playback survive a sleeping Mac is a
different job: sync `out/` to **R2** and put a Worker in front to serve the
library and files. Separation would still need the Mac, or a GPU host — R2 and
a Worker only remove the Mac from the *playback* path.

## Adding a song

The **+** tab is the one way in:

- **Paste a link.** Anything yt-dlp understands, not only YouTube. A pasted
  link becomes a one-song batch, so progress and match confirmation look the
  same however the song was chosen.
- **Apple Music**, once the library is authorised: playlists and albums with
  artwork, plus search across every song by title or artist.
- **Spotify**, once connected: your playlists, plus Spotify's catalogue search
  so a song that is in no playlist is still reachable.

Selecting from either service picks the *song*, not its audio -- see below.

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
