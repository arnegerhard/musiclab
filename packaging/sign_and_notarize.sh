#!/bin/bash
# Sign and notarize "Musiclab Worker.app" so that a Mac which downloaded it
# will open it.
#
#   ./packaging/sign_and_notarize.sh [path-to-.app]
#
# An ad-hoc signature is enough for the Mac that built the app and refused
# everywhere else: a download carries a quarantine flag, and Gatekeeper wants
# a Developer ID signature and a notarization ticket before it will run.
#
# Environment:
#   SIGN_IDENTITY   certificate name (default: the Developer ID in the keychain)
#   NOTARY_PROFILE  notarytool keychain profile (default: musiclab)
#   SKIP_NOTARIZE   set to 1 to sign only -- useful for checking the signing
#                   pass with a Development certificate, which can never be
#                   notarized but exercises everything else.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Musiclab Worker.app}"
ENTITLEMENTS="$ROOT/macos/MusiclabWorker.entitlements"
PROFILE="${NOTARY_PROFILE:-musiclab}"

[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 \
    | sed 's/.*"\(.*\)"/\1/')}"
[ -n "$IDENTITY" ] || {
    echo "No Developer ID Application certificate."
    echo "Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
    exit 1
}
echo "==> Signing as: $IDENTITY"

# Everything inside first, the bundle last: a signature covers the bytes of
# what it wraps, so signing the outside before the inside seals a hash that
# the next inner signature invalidates.
echo "==> Finding native code inside the bundle"
MACHOS="$(mktemp)"
# The loop's status is whatever the last file's `grep -q` said, so a bundle
# whose last candidate is not Mach-O would fail the whole script under set -e.
find "$APP" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) \
    | while IFS= read -r f; do
        if file "$f" 2>/dev/null | grep -q "Mach-O"; then printf '%s\n' "$f"; fi
      done > "$MACHOS" || true
echo "    $(wc -l < "$MACHOS" | tr -d ' ') binaries"

# Deepest first, and in parallel: they are independent of each other, and one
# of them is a 368 MB libtorch.
echo "==> Signing them"
awk '{ print gsub(/\//, "/") "\t" $0 }' "$MACHOS" | sort -rn | cut -f2- \
    | tr '\n' '\0' \
    | xargs -0 -P 8 -I{} codesign --force --timestamp --options runtime \
        --sign "$IDENTITY" "{}" 2>&1 | grep -v ": replacing existing signature" || true
rm -f "$MACHOS"

echo "==> Signing the bundle"
codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "==> Skipping notarization (SKIP_NOTARIZE=1)"
    exit 0
fi

# Notarization takes an archive, not a bundle, and gives back a ticket which
# has to be stapled into the app -- otherwise every launch needs the network
# to ask Apple whether this app is known.
ZIP="$ROOT/dist/notarize.zip"
echo "==> Uploading for notarization (this takes a while)"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$ZIP"

echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" | sed 's/^/    /'

# The distributable archive has to be made after stapling: the ticket lives
# inside the bundle, and an archive made before it does not carry one.
OUT="$ROOT/dist/Musiclab-Worker.zip"
echo "==> Repacking $OUT"
rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"
ls -la "$OUT" | awk '{printf "    %.0f MB\n", $5/1048576}'

echo "==> Gatekeeper's verdict"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/    /'
