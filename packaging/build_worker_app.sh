#!/bin/bash
# Build "Musiclab Worker.app": a menu bar app carrying its own Python.
#
#   ./packaging/build_worker_app.sh [output-directory]
#
# Two halves. The Swift app is the face: a light in the menu bar, a progress
# bar, and what it is doing. The Python inside Resources does the work.
# They talk through a status file rather than a socket, so either can restart
# without the other noticing.
#
# The models (~1.3 GB) are not bundled. They download on first run into
# Application Support -- never into the bundle, which would invalidate its
# signature and be discarded by the next update.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
PYTHON_VERSION="3.12"

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen"; exit 1; }

echo "==> Building the menu bar app"
( cd "$ROOT/macos" && xcodegen generate >/dev/null )
xcodebuild -project "$ROOT/macos/MusiclabWorker.xcodeproj" \
    -scheme MusiclabWorker -configuration Release \
    -derivedDataPath "$ROOT/macos/build" build >/dev/null

BUILT="$ROOT/macos/build/Build/Products/Release/Musiclab Worker.app"
[ -d "$BUILT" ] || { echo "the app did not build"; exit 1; }

APP="$OUT/Musiclab Worker.app"
mkdir -p "$OUT"
rm -rf "$APP"
cp -R "$BUILT" "$APP"

# The interpreter has to be *in* the bundle, not referred to from it. A venv
# will not do that: uv builds one whose bin/python is a symlink to this Mac's
# own Python and whose pyvenv.cfg names it by absolute path, so the app runs
# here and nowhere else -- and nothing about it looks broken until someone
# else downloads it. These standalone builds work out their own prefix from
# the executable's location, so a plain copy relocates anywhere.
echo "==> Copying Python $PYTHON_VERSION into the bundle"
PROBE="$(mktemp -d)/probe"
uv venv --python "$PYTHON_VERSION" --no-project "$PROBE" >/dev/null
BASE="$(cd "$(grep '^home = ' "$PROBE/pyvenv.cfg" | cut -d' ' -f3-)/.." && pwd)"
rm -rf "$(dirname "$PROBE")"
[ -x "$BASE/bin/python$PYTHON_VERSION" ] || { echo "no interpreter at $BASE"; exit 1; }

PY="$APP/Contents/Resources/python"
# The built app has no Resources directory of its own; uv venv used to create
# one as a side effect.
mkdir -p "$APP/Contents/Resources"
rm -rf "$PY"
cp -R "$BASE" "$PY"
# It was uv's; it is ours now, and uv refuses to install into one it manages.
find "$PY" -name "EXTERNALLY-MANAGED" -delete

echo "==> Installing the worker (this pulls PyTorch, a few hundred MB)"
uv pip install --quiet --python "$PY/bin/python$PYTHON_VERSION" "$ROOT[worker]"

# Check from a directory that is not the checkout. Run from inside it and
# Python puts the source on sys.path, so the bundle is never exercised and the
# check passes without proving anything.
echo "==> Checking the bundle stands alone"
( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin \
    "$PY/bin/python$PYTHON_VERSION" - <<'PYCHECK'
import os
import sys
import stems
from stems.config import MODEL_DIR
from stems.media import ffmpeg_path

# The old check proved the packages were in the bundle while the interpreter
# running them came from this Mac -- which is exactly how a bundle that only
# works here passes its own test.
assert ".app/Contents/" in sys.executable, "the interpreter is not in the bundle"
assert ".app/Contents/" in stems.__file__, "imported something other than the bundle"
assert ".app/Contents/" not in str(MODEL_DIR), "state would be written into the bundle"
assert os.path.exists(ffmpeg_path()), "ffmpeg is missing"
print(f"    imports from the bundle, ffmpeg present, state in {MODEL_DIR.parent}")
PYCHECK
)

SIZE=$(du -sh "$APP" | cut -f1)
echo "==> Built $APP ($SIZE)"
echo
echo "Ad-hoc signed, which any Mac that downloaded it will refuse. To distribute:"
echo "  ./packaging/sign_and_notarize.sh"
