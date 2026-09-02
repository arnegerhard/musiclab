# Musiclab

Splits a song into its separate parts and lets you stand them around a room
on your phone.

---

## 1. Installing it

Everything here runs on your own machines and your own accounts. There is no
hosted service to sign up for.

### What you need

- A Mac with Apple silicon (M1 or later) — it does the separating.
- [Homebrew](https://brew.sh), for the three tools below.
- Xcode, if you want the iPhone app. A paid Apple Developer account is needed
  to run it on a real phone; the Simulator works without one.

```bash
brew install ffmpeg uv xcodegen
```

### Get the code

```bash
git clone https://github.com/arnegerhard/musiclab.git
cd musiclab
uv venv --python 3.12 && uv pip install -e .
```

The separation models are about 1 GB. They download themselves the first
time they are needed and are cached afterwards.

### Try it without any of the apps

```bash
.venv/bin/python -m stems.cli "https://www.youtube.com/watch?v=..."
```

That writes fourteen files into `out/`. If this is all you want, you can stop
reading here.

### Choose where the server lives

**On your Mac**, if you only listen at home:

```bash
.venv/bin/python -m stems.cli --add-user you@example.com
.venv/bin/python -m stems.cli --serve
```

The phone finds it on the local network by itself.

**On Modal**, if you want it to work anywhere. Separation can then run on a
rented GPU, billed by the second:

```bash
uv pip install modal && modal token new
modal deploy modal_app.py
MUSICLAB_PASSWORD=... modal run modal_app.py::account --email you@example.com
```

Note the URL it prints — the phone needs it.

### Build the Mac worker

The worker is what actually separates songs for a deployed server, and the
only thing that can download from YouTube: YouTube answers a home connection
and refuses a datacenter one.

```bash
bash packaging/build_worker_app.sh
open "dist/Musiclab Worker.app"
```

It is a single self-contained app — Python, the models and `ffmpeg` are all
inside it, so nothing has to be installed to run it. It lives in the menu bar.
Unsigned, so macOS will warn the first time you open it.

### Build the iPhone app

```bash
open ios/Musiclab.xcodeproj
```

Two settings before it will work:

- **Signing & Capabilities** — select your team.
- **Build Settings → `MUSICLAB_CLOUD_URL`** — your Modal URL from above.

### Pair the two

Open the app, sign in, then **⋯ → Pair a Mac**. An unpaired Mac offers itself
on the local network; tap it, and both screens show the same six digits. Agree
on the phone, allow on the Mac, and it is done. Nothing is typed, and the
Mac never receives your password.

---

## 2. What it does

### Seven stems, in two passes

A song goes through two models in turn, the second splitting what the first
left:

| Pass | Produces |
| --- | --- |
| Six-way split | vocals, drums, bass, guitar, piano, other |
| Lead vs. backing vocals | lead vocal, backing vocals |

Seven stems, each stored at about the size of an MP3 of the whole song.

On an M4 MacBook Air a three-minute song takes something like ten minutes;
the vocal pass is most of it. A rented GPU is several times quicker, and
charges by the second.

### A room you can arrange

The phone plays every stem at once as a separate point in space. Drag the
musicians around a floor plan, pick a room — living room through cathedral —
and each source gets quieter and more reverberant as you push it away.

With AirPods, head tracking keeps the band still while you turn: turn left and
the guitarist stays where you put them. Playback continues when you leave the
screen.

### Adding songs

- **A link** — anything `yt-dlp` understands. Needs a paired Mac to fetch it.
- **A file you already have** — MP3, M4A, FLAC, WAV, OGG. Converted for you,
  and the one route that needs no Mac at all.
- **Apple Music or Spotify** — browse your playlists and pick tracks; the
  matching song is found and separated.

Every song asks where it should be worked on: on a Mac, free and unhurried, or
in the cloud for money and speed.

### A queue that tells you the truth

The Queue tab is badged with what is outstanding and shows each song's stage,
its progress bar, and which machine has it — the same thing the Mac's own menu
bar panel is showing. Anything stuck can be cancelled.

### Accounts and machines

Songs are private to the account that asked for them. Sign in with an email
and password or with Apple. Each paired Mac holds a credential of its own,
good for claiming work and returning it and nothing else, revocable one
machine at a time from the phone.

### What it cannot do

Worth knowing before you are disappointed:

- **Harmonies do not separate.** "Backing vocals" is every non-lead voice
  together, not one track per singer.
- **Layered guitars stay layered.** Six guitar takes come back as one guitar
  stem.
- **Brass and strings** are not separated from each other, or from anything
  else; they land in "other".
- **Height is inaudible.** Sources are placed around you convincingly, but
  moving one up or down does nothing you can hear — binaural rendering carries
  direction well and elevation badly without a hearing profile matched to your
  own ears.
- **Separation is imperfect.** Quiet passages bleed between stems, and cymbals
  smear. It is very good, not surgical.
