#!/bin/bash
# Entry point inside Musiclab Worker.app.
#
# Asks for the server and an account the first time, keeps the session token in
# the login keychain rather than on disk, and restarts the worker if it dies.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="$HERE/Resources/venv/bin/python"
SUPPORT="$HOME/Library/Application Support/Musiclab"
CONFIG="$SUPPORT/worker.json"
LOG="$HOME/Library/Logs/Musiclab/worker.log"
KEYCHAIN_ACCOUNT="musiclab-worker"

mkdir -p "$SUPPORT" "$(dirname "$LOG")"

# Models and any scratch belong beside the user's data, never inside the
# bundle: writing there would invalidate the code signature.
export STEMS_MODEL_DIR="$SUPPORT/models"
export STEMS_OUT_DIR="$SUPPORT/out"

ask() {  # prompt, default, hidden
    local hidden=""
    [ "${3:-}" = "hidden" ] && hidden="with hidden answer"
    osascript -e "display dialog \"$1\" default answer \"$2\" $hidden with title \"Musiclab Worker\"" \
        -e 'text returned of result' 2>/dev/null
}

notify() {
    osascript -e "display notification \"$1\" with title \"Musiclab Worker\"" 2>/dev/null
}

if [ ! -f "$CONFIG" ]; then
    SERVER=$(ask "Which Musiclab server should this Mac work for?" "https://arnegerhard--musiclab-web.modal.run") || exit 0
    [ -z "$SERVER" ] && exit 0
    EMAIL=$(ask "Sign in as:" "") || exit 0
    [ -z "$EMAIL" ] && exit 0
    PASSWORD=$(ask "Password for $EMAIL:" "" hidden) || exit 0

    # Exchange the password for a token immediately and keep only the token,
    # so the password is never written anywhere.
    TOKEN=$("$PYTHON" -c "
import sys
from stems.agent import sign_in
try:
    print(sign_in(sys.argv[1], sys.argv[2], sys.argv[3]))
except Exception as exc:
    sys.exit(str(exc))
" "$SERVER" "$EMAIL" "$PASSWORD" 2>>"$LOG")

    if [ -z "$TOKEN" ]; then
        osascript -e 'display alert "Could not sign in" message "Check the address, email and password, then open Musiclab Worker again."' 2>/dev/null
        exit 1
    fi

    security add-generic-password -U -a "$KEYCHAIN_ACCOUNT" -s "musiclab" -w "$TOKEN" 2>/dev/null
    printf '{"server": "%s", "email": "%s"}\n' "$SERVER" "$EMAIL" > "$CONFIG"
    notify "Signed in. This Mac will now take work."
fi

SERVER=$("$PYTHON" -c "import json,sys; print(json.load(open(sys.argv[1]))['server'])" "$CONFIG")
TOKEN=$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "musiclab" -w 2>/dev/null)

if [ -z "$TOKEN" ]; then
    rm -f "$CONFIG"          # keychain entry gone: start setup again next open
    osascript -e 'display alert "Signed out" message "Open Musiclab Worker again to sign in."' 2>/dev/null
    exit 1
fi

notify "Watching for songs to separate."
echo "=== $(date) starting worker for $SERVER ===" >> "$LOG"

# A worker that dies should come back; the machine may have slept, or the
# network may have gone away for a while.
while true; do
    MUSICLAB_SERVER="$SERVER" MUSICLAB_TOKEN="$TOKEN" "$PYTHON" -c "
import os
from stems.agent import Worker
Worker(os.environ['MUSICLAB_SERVER'], os.environ['MUSICLAB_TOKEN']).run()
" >> "$LOG" 2>&1
    echo "=== $(date) worker exited, retrying in 30s ===" >> "$LOG"
    sleep 30
done
