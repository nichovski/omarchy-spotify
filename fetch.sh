#!/usr/bin/env bash
# Fetch currently playing Spotify track and write to JSON file.
# Uses stored credentials from ~/.config/omarchy/spotify/credentials.env
#
# Quota-friendly behaviour:
#   - access token is cached and reused until it is about to expire
#   - device list is cached and refreshed at most every DEVICES_TTL seconds
#   - "Retry-After" from a 429 is honoured: no API call is made until it elapses
#   - other errors apply a short back-off so we never hot-loop

set -euo pipefail

CRED_FILE="$HOME/.config/omarchy/spotify/credentials.env"
OUTPUT_FILE="$HOME/.config/omarchy/spotify/now_playing.json"
TOKEN_FILE="$HOME/.config/omarchy/spotify/token.json"

DEVICES_TTL=60        # seconds between device-list refreshes
ERROR_BACKOFF=60      # seconds to wait after a non-429 error
DEFAULT_RETRY=300     # fallback when Retry-After is missing/unparseable

now() { date +%s; }

write_state() { # <json-string>
  printf '%s\n' "$1" > "$OUTPUT_FILE.tmp" && mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"
}

write_error() { # <message> [backoff-seconds]
  local msg="$1" backoff="${2:-$ERROR_BACKOFF}" t
  t=$(( $(now) + backoff ))
  write_state "$(jq -n --arg e "$msg" --argjson t "$t" \
    '{error: $e, retry_at: $t}')"
  exit 0
}

# Keep the last known track/device state, but record when the API may be called again.
write_rate_limited() { # <retry-after-seconds>
  local ra="$1" t mins
  t=$(( $(now) + ra ))
  mins=$(( ra / 60 + 1 ))
  if [[ -f "$OUTPUT_FILE" ]] && jq -e . "$OUTPUT_FILE" >/dev/null 2>&1; then
    write_state "$(jq --argjson t "$t" --argjson ra "$ra" \
      --arg msg "Spotify rate limit — retrying in ~${mins} min" \
      '.error = $msg | .retry_at = $t | .retry_after = $ra' "$OUTPUT_FILE")"
  else
    write_state "$(jq -n --argjson t "$t" --argjson ra "$ra" \
      --arg msg "Spotify rate limit — retrying in ~${mins} min" \
      '{error: $msg, retry_at: $t, retry_after: $ra, is_playing: false}')"
  fi
  exit 0
}

# Load credentials
if [[ ! -f "$CRED_FILE" ]]; then
  write_error "No credentials found. Run: python3 ~/.config/omarchy/plugins/nichovski.spotify/setup.py" 3600
fi

source "$CRED_FILE"

if [[ -z "${SPOTIFY_CLIENT_ID:-}" || -z "${SPOTIFY_CLIENT_SECRET:-}" || -z "${SPOTIFY_REFRESH_TOKEN:-}" ]]; then
  write_error "Incomplete credentials. Run: python3 ~/.config/omarchy/plugins/nichovski.spotify/setup.py" 3600
fi

NOW=$(now)

# Inside a rate-limit / back-off window? Do not touch the API at all.
if [[ -f "$OUTPUT_FILE" ]]; then
  RETRY_AT=$(jq -r '.retry_at // 0' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  if [[ "$RETRY_AT" =~ ^[0-9]+$ ]] && (( RETRY_AT > NOW )); then
    exit 0
  fi
fi

# --- Access token (cached until shortly before expiry) ---
ACCESS_TOKEN=""
if [[ -f "$TOKEN_FILE" ]]; then
  TOK_EXP=$(jq -r '.expires_at // 0' "$TOKEN_FILE" 2>/dev/null || echo 0)
  if [[ "$TOK_EXP" =~ ^[0-9]+$ ]] && (( TOK_EXP > NOW + 30 )); then
    ACCESS_TOKEN=$(jq -r '.access_token // empty' "$TOKEN_FILE" 2>/dev/null || echo "")
  fi
fi

if [[ -z "$ACCESS_TOKEN" ]]; then
  TOKEN_RESPONSE=$(curl -s -X POST "https://accounts.spotify.com/api/token" \
    -d "grant_type=refresh_token" \
    -d "refresh_token=$SPOTIFY_REFRESH_TOKEN" \
    -H "Authorization: Basic $(echo -n "$SPOTIFY_CLIENT_ID:$SPOTIFY_CLIENT_SECRET" | base64 -w 0)" \
    -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null || echo '{}')

  ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null || echo "")
  EXPIRES_IN=$(echo "$TOKEN_RESPONSE" | jq -r '.expires_in // 3600' 2>/dev/null || echo 3600)

  if [[ -z "$ACCESS_TOKEN" ]]; then
    write_error "Failed to refresh token. Credentials may be expired. Run: python3 ~/.config/omarchy/plugins/nichovski.spotify/setup.py" 300
  fi

  jq -n --arg t "$ACCESS_TOKEN" --argjson e "$(( NOW + EXPIRES_IN ))" \
    '{access_token: $t, expires_at: $e}' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi

# --- Device list (cached for DEVICES_TTL seconds) ---
DEVICES_LIST='[]'
DEVICES_FETCHED_AT=0
if [[ -f "$OUTPUT_FILE" ]]; then
  CACHED_AT=$(jq -r '.devices_fetched_at // 0' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  if [[ "$CACHED_AT" =~ ^[0-9]+$ ]] && (( NOW - CACHED_AT < DEVICES_TTL )); then
    DEVICES_LIST=$(jq -c '.devices // []' "$OUTPUT_FILE" 2>/dev/null || echo '[]')
    DEVICES_FETCHED_AT=$CACHED_AT
  fi
fi

# --- Currently playing (capture headers so we can read Retry-After) ---
HDRS=$(mktemp)
trap 'rm -f "$HDRS"' EXIT

RESPONSE=$(curl -s -D "$HDRS" -w "\n%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://api.spotify.com/v1/me/player/currently-playing" 2>/dev/null || printf '\n000')

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "429" ]]; then
  RETRY_AFTER=$(awk 'BEGIN{IGNORECASE=1} /^retry-after:/ {gsub(/\r/,"",$2); print $2}' "$HDRS" | tail -n1)
  [[ "$RETRY_AFTER" =~ ^[0-9]+$ ]] || RETRY_AFTER=$DEFAULT_RETRY
  write_rate_limited "$RETRY_AFTER"
fi

# --- Refresh devices only when the cache is stale ---
if (( DEVICES_FETCHED_AT == 0 )); then
  DEVICES_JSON=$(curl -s \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://api.spotify.com/v1/me/player/devices" 2>/dev/null || echo '{}')
  if echo "$DEVICES_JSON" | jq -e . >/dev/null 2>&1; then
    DEVICES_LIST=$(echo "$DEVICES_JSON" | jq -c '[.devices // [] | .[] | {id, name, type, is_active}]' 2>/dev/null || echo '[]')
  else
    DEVICES_LIST='[]'
  fi
  DEVICES_FETCHED_AT=$NOW
fi

# --- Nothing currently playing ---
if [[ "$HTTP_CODE" == "204" || -z "$BODY" || "$BODY" == "null" ]]; then
  write_state "$(jq -n --argjson devices "$DEVICES_LIST" --argjson fetched "$DEVICES_FETCHED_AT" '{
    is_playing: false,
    devices: $devices,
    devices_fetched_at: $fetched
  }')"
  exit 0
fi

if [[ "$HTTP_CODE" != "200" ]]; then
  write_error "Spotify API error (HTTP $HTTP_CODE)"
fi

# --- Playing: build output in one pass ---
write_state "$(echo "$BODY" | jq --argjson devices "$DEVICES_LIST" --argjson fetched "$DEVICES_FETCHED_AT" '{
  is_playing: (.is_playing // false),
  title: (.item.name // ""),
  artist: ([.item.artists[]?.name] | join(", ")),
  album: (.item.album.name // ""),
  art_url: (.item.album.images[0].url // .item.album.images[1].url // ""),
  progress_ms: (.progress_ms // 0),
  duration_ms: (.item.duration_ms // 0),
  device: (.device.name // ""),
  device_id: (.device.id // ""),
  devices: $devices,
  devices_fetched_at: $fetched,
  timestamp: (now | floor)
}')"
