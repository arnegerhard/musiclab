#!/bin/bash
# Build "Musiclab Worker.app": a self-contained worker that needs nothing
# installed. Python, PyTorch and ffmpeg all live inside the bundle.
#
#   ./packaging/build_worker_app.sh [output-directory]
#
# The models (~1.3 GB) are not bundled. They are fetched on first run into
# Application Support, so the download is not paid twice by anyone who already
# has them, and the .app stays a manageable size.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
APP="$OUT/Musiclab Worker.app"
PYTHON_VERSION="3.12"

echo "==> Building into $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# A relocatable venv: its scripts must not hard-code the path it was built at,
# because it is about to be moved into a bundle and then onto someone else's Mac.
echo "==> Creating a relocatable Python $PYTHON_VERSION"
uv venv --python "$PYTHON_VERSION" --relocatable --no-project "$APP/Contents/Resources/venv" >/dev/null

echo "==> Installing the worker (this pulls PyTorch, a few hundred MB)"
VIRTUAL_ENV="$APP/Contents/Resources/venv" uv pip install --quiet \
    --python "$APP/Contents/Resources/venv/bin/python" \
    "$ROOT[worker]"

# Prove ffmpeg came along; without it nothing decodes.
"$APP/Contents/Resources/venv/bin/python" - <<'PYCHECK'
import imageio_ffmpeg, os, sys
exe = imageio_ffmpeg.get_ffmpeg_exe()
if not os.path.exists(exe):
    sys.exit("ffmpeg is missing from the bundle")
print(f"    ffmpeg bundled: {os.path.basename(exe)}")
PYCHECK

cp "$ROOT/packaging/launcher.sh" "$APP/Contents/MacOS/MusiclabWorker"
chmod +x "$APP/Contents/MacOS/MusiclabWorker"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Musiclab Worker</string>
    <key>CFBundleDisplayName</key><string>Musiclab Worker</string>
    <key>CFBundleIdentifier</key><string>info.jetsons.musiclab.worker</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>MusiclabWorker</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <!-- No window: it lives in the background and logs to a file. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

SIZE=$(du -sh "$APP" | cut -f1)
echo "==> Built $APP ($SIZE)"
echo
echo "To sign it for distribution (unsigned, macOS will warn on first open):"
echo "  codesign --deep --force --sign \"Developer ID Application: NAME\" \"$APP\""
echo "  xcrun notarytool submit ... && xcrun stapler staple \"$APP\""
