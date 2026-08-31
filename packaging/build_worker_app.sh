#!/bin/bash
# Build "Musiclab Worker.app": a menu bar app carrying its own Python.
#
#   ./packaging/build_worker_app.sh [output-directory]
#
# Two halves. The Swift app is the face: a light in the menu bar, a progress
# bar, and what it is doing. The Python venv inside Resources does the work.
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

# A relocatable venv: its scripts must not hard-code the path it was built at,
# because it is about to move into a bundle and then onto someone else's Mac.
echo "==> Creating a relocatable Python $PYTHON_VERSION inside the bundle"
uv venv --python "$PYTHON_VERSION" --relocatable --no-project \
    "$APP/Contents/Resources/venv" >/dev/null

echo "==> Installing the worker (this pulls PyTorch, a few hundred MB)"
uv pip install --quiet --python "$APP/Contents/Resources/venv/bin/python" "$ROOT[worker]"

# Check from a directory that is not the checkout. Run from inside it and
# Python puts the source on sys.path, so the bundle is never exercised and the
# check passes without proving anything.
echo "==> Checking the bundle stands alone"
( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin \
    "$APP/Contents/Resources/venv/bin/python" - <<'PYCHECK'
import os
import stems
from stems.config import MODEL_DIR
from stems.media import ffmpeg_path

assert ".app/Contents/" in stems.__file__, "imported something other than the bundle"
assert ".app/Contents/" not in str(MODEL_DIR), "state would be written into the bundle"
assert os.path.exists(ffmpeg_path()), "ffmpeg is missing"
print(f"    imports from the bundle, ffmpeg present, state in {MODEL_DIR.parent}")
PYCHECK
)

SIZE=$(du -sh "$APP" | cut -f1)
echo "==> Built $APP ($SIZE)"
echo
echo "Unsigned: macOS will warn on first open. To distribute:"
echo "  codesign --deep --force --options runtime --sign \"Developer ID Application: NAME\" \"$APP\""
echo "  xcrun notarytool submit ... && xcrun stapler staple \"$APP\""
