#!/usr/bin/env bash
# Send a playback control command to Spotify via the Web API.
# Controls whatever device is currently active on the account (Spotify Connect).
#
# Usage: control.sh <play|pause|playpause|next|previous|device> [device-id]
#
# All HTTP is done by spotify_api.py: it reads the credentials itself, keeps
# secrets off the process command line, bounds every request with connect and
# total deadlines, and enforces a hard response-size cap.

set -euo pipefail

ACTION="${1:-}"
CRED_FILE="$HOME/.config/omarchy/spotify/credentials.env"
NP_FILE="$HOME/.config/omarchy/spotify/now_playing.json"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_PY="$DIR/spotify_api.py"

[[ -f "$CRED_FILE" ]] || exit 0

api_call() { # <args...>
  python3 "$API_PY" "$@" >/dev/null 2>&1 || true
}

case "$ACTION" in
  play|pause)
    api_call control "$ACTION"
    ;;
  playpause)
    PLAYING=$(jq -r '.is_playing // false' "$NP_FILE" 2>/dev/null || echo "false")
    if [[ "$PLAYING" == "true" ]]; then
      api_call control pause
    else
      api_call control play
    fi
    ;;
  next|previous)
    api_call control "$ACTION"
    ;;
  device)
    DEVICE_ID="${2:-}"
    [[ -z "$DEVICE_ID" ]] && exit 1
    # Transfer playback to the chosen device and start playing there
    api_call transfer "$DEVICE_ID"
    ;;
  *)
    exit 1
    ;;
esac

# Refresh local state so the widget updates immediately
bash "$DIR/fetch.sh" || true