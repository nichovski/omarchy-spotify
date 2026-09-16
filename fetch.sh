#!/usr/bin/env bash
# Fetch currently playing Spotify track and write to JSON file.
# Uses stored credentials from ~/.config/omarchy/spotify/credentials.env

set -euo pipefail

CRED_FILE="$HOME/.config/omarchy/spotify/credentials.env"
OUTPUT_FILE="$HOME/.config/omarchy/spotify/now_playing.json"

write_error() {
  jq -n --arg e "$1" '{error: $e}' > "$OUTPUT_FILE"
  exit 0
}

# Load credentials
if [[ ! -f "$CRED_FILE" ]]; then
  write_error "No credentials found. Run: python3 ~/.config/omarchy/plugins/spotify/setup.py"
fi

source "$CRED_FILE"

if [[ -z "${SPOTIFY_CLIENT_ID:-}" || -z "${SPOTIFY_CLIENT_SECRET:-}" || -z "${SPOTIFY_REFRESH_TOKEN:-}" ]]; then
  write_error "Incomplete credentials. Run: python3 ~/.config/omarchy/plugins/spotify/setup.py"
fi

# Refresh access token
TOKEN_RESPONSE=$(curl -s -X POST "https://accounts.spotify.com/api/token" \
  -d "grant_type=refresh_token" \
  -d "refresh_token=$SPOTIFY_REFRESH_TOKEN" \
  -H "Authorization: Basic $(echo -n "$SPOTIFY_CLIENT_ID:$SPOTIFY_CLIENT_SECRET" | base64 -w 0)" \
  -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null || echo '{}')

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null || echo "")

if [[ -z "$ACCESS_TOKEN" ]]; then
  write_error "Failed to refresh token. Credentials may be expired. Run: python3 ~/.config/omarchy/plugins/spotify/setup.py"
fi

# Fetch currently playing
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://api.spotify.com/v1/me/player/currently-playing" 2>/dev/null)

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

# Fetch available devices (best-effort; never fails the fetch)
DEVICES=$(curl -s \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://api.spotify.com/v1/me/player/devices" 2>/dev/null || echo '{}')
if ! echo "$DEVICES" | jq -e . >/dev/null 2>&1; then
  DEVICES='{}'
fi

if [[ "$HTTP_CODE" == "204" || -z "$BODY" || "$BODY" == "null" ]]; then
  jq -n --argjson devices "$DEVICES" '{
    is_playing: false,
    devices: ($devices.devices // [] | map({id, name, type, is_active}))
  }' > "$OUTPUT_FILE"
  exit 0
fi

if [[ "$HTTP_CODE" != "200" ]]; then
  write_error "Spotify API error (HTTP $HTTP_CODE)"
fi

# Build output JSON in one pass — avoids quoting/newline issues
echo "$BODY" | jq --argjson devices "$DEVICES" '{
  is_playing: (.is_playing // false),
  title: (.item.name // ""),
  artist: ([.item.artists[]?.name] | join(", ")),
  album: (.item.album.name // ""),
  art_url: (.item.album.images[0].url // .item.album.images[1].url // ""),
  progress_ms: (.progress_ms // 0),
  duration_ms: (.item.duration_ms // 0),
  device: (.device.name // ""),
  device_id: (.device.id // ""),
  devices: ($devices.devices // [] | map({id, name, type, is_active})),
  timestamp: (now | floor)
}' > "$OUTPUT_FILE"
