#!/usr/bin/env bash
# Send a playback control command to Spotify via the Web API.
# Controls whatever device is currently active on the account (Spotify Connect).
#
# Usage: control.sh <play|pause|playpause|next|previous>

set -euo pipefail

ACTION="${1:-}"
CRED_FILE="$HOME/.config/omarchy/spotify/credentials.env"
NP_FILE="$HOME/.config/omarchy/spotify/now_playing.json"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$CRED_FILE" ]] || exit 0
source "$CRED_FILE"

if [[ -z "${SPOTIFY_CLIENT_ID:-}" || -z "${SPOTIFY_CLIENT_SECRET:-}" || -z "${SPOTIFY_REFRESH_TOKEN:-}" ]]; then
  exit 1
fi

# Refresh access token
TOKEN_RESPONSE=$(curl -s -X POST "https://accounts.spotify.com/api/token" \
  -d "grant_type=refresh_token" \
  -d "refresh_token=$SPOTIFY_REFRESH_TOKEN" \
  -H "Authorization: Basic $(echo -n "$SPOTIFY_CLIENT_ID:$SPOTIFY_CLIENT_SECRET" | base64 -w 0)" \
  -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null || echo '{}')

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null || echo "")
[[ -z "$ACCESS_TOKEN" ]] && exit 1

api() { # method endpoint
  curl -s -X "$1" -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://api.spotify.com/v1/me/player/$2" >/dev/null 2>&1 || true
}

case "$ACTION" in
  play|pause)
    api PUT "$ACTION"
    ;;
  playpause)
    PLAYING=$(jq -r '.is_playing // false' "$NP_FILE" 2>/dev/null || echo "false")
    if [[ "$PLAYING" == "true" ]]; then
      api PUT "pause"
    else
      api PUT "play"
    fi
    ;;
  next|previous)
    api POST "$ACTION"
    ;;
  *)
    exit 1
    ;;
esac

# Refresh local state so the widget updates immediately
bash "$DIR/fetch.sh" || true
