#!/usr/bin/env bash
# Fetch currently playing Spotify track and write to JSON file.
# Uses stored credentials from ~/.config/omarchy/spotify/credentials.env

set -euo pipefail

CRED_FILE="$HOME/.config/omarchy/spotify/credentials.env"
OUTPUT_FILE="$HOME/.config/omarchy/spotify/now_playing.json"

# Load credentials
if [[ ! -f "$CRED_FILE" ]]; then
  echo '{"error":"No credentials found. Run: python3 ~/.config/omarchy/plugins/spotify/setup.py"}' > "$OUTPUT_FILE"
  exit 0
fi

source "$CRED_FILE"

if [[ -z "${SPOTIFY_CLIENT_ID:-}" || -z "${SPOTIFY_CLIENT_SECRET:-}" || -z "${SPOTIFY_REFRESH_TOKEN:-}" ]]; then
  echo '{"error":"Incomplete credentials. Run: python3 ~/.config/omarchy/plugins/spotify/setup.py"}' > "$OUTPUT_FILE"
  exit 0
fi

# Refresh access token
TOKEN_RESPONSE=$(curl -s -X POST "https://accounts.spotify.com/api/token" \
  -d "grant_type=refresh_token" \
  -d "refresh_token=$SPOTIFY_REFRESH_TOKEN" \
  -H "Authorization: Basic $(echo -n "$SPOTIFY_CLIENT_ID:$SPOTIFY_CLIENT_SECRET" | base64 -w 0)" \
  -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null || echo '{}')

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null || echo "")

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo '{"error":"Failed to refresh token. Credentials may be expired. Run: python3 ~/.config/omarchy/plugins/spotify/setup.py"}' > "$OUTPUT_FILE"
  exit 0
fi

# Fetch currently playing
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://api.spotify.com/v1/me/player/currently-playing" 2>/dev/null)

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "204" || -z "$BODY" || "$BODY" == "null" ]]; then
  echo '{"is_playing":false}' > "$OUTPUT_FILE"
  exit 0
fi

if [[ "$HTTP_CODE" != "200" ]]; then
  echo '{"error":"Spotify API error (HTTP '"$HTTP_CODE"')"}' > "$OUTPUT_FILE"
  exit 0
fi

# Extract track info
TITLE=$(echo "$BODY" | jq -r '.item.name // ""' 2>/dev/null || echo "")
ARTIST=$(echo "$BODY" | jq -r '[.item.artists[].name] | join(", ")' 2>/dev/null || echo "")
ALBUM=$(echo "$BODY" | jq -r '.item.album.name // ""' 2>/dev/null || echo "")
ART_URL=$(echo "$BODY" | jq -r '.item.album.images[0].url // .item.album.images[1].url // ""' 2>/dev/null || echo "")
IS_PLAYING=$(echo "$BODY" | jq -r '.is_playing // false' 2>/dev/null || echo "false")
PROGRESS=$(echo "$BODY" | jq -r '.progress_ms // 0' 2>/dev/null || echo "0")
DURATION=$(echo "$BODY" | jq -r '.item.duration_ms // 0' 2>/dev/null || echo "0")

# Build output JSON
cat > "$OUTPUT_FILE" <<EOF
{
  "is_playing": $IS_PLAYING,
  "title": $(echo "$TITLE" | jq -Rs .),
  "artist": $(echo "$ARTIST" | jq -Rs .),
  "album": $(echo "$ALBUM" | jq -Rs .),
  "art_url": $(echo "$ART_URL" | jq -Rs .),
  "progress_ms": $PROGRESS,
  "duration_ms": $DURATION,
  "timestamp": $(date +%s)
}
EOF
