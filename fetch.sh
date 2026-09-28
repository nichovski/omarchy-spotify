#!/usr/bin/env bash
# Fetch currently playing Spotify track and write to JSON file.
# Uses stored credentials from ~/.config/omarchy/spotify/credentials.env
#
# Quota-friendly behaviour:
#   - access token is cached and reused until it is about to expire
#   - device list is cached and refreshed at most every DEVICES_TTL seconds
#   - "Retry-After" from a 429 is honoured: no API call is made until it elapses
#   - other errors apply a short back-off so we never hot-loop
#
# All HTTP is done by spotify_api.py: it reads the credentials itself, keeps
# secrets off the process command line, bounds every request with connect and
# total deadlines, and enforces a hard response-size cap.

set -euo pipefail

CRED_FILE="$HOME/.config/omarchy/spotify/credentials.env"
OUTPUT_FILE="$HOME/.config/omarchy/spotify/now_playing.json"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_PY="$DIR/spotify_api.py"

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

# Call spotify_api.py and always return a JSON envelope, even if it crashes.
api_call() { # <args...>
  python3 "$API_PY" "$@" 2>/dev/null || printf '{"status":0,"error":"spotify_api.py failed"}'
}

if [[ ! -f "$CRED_FILE" ]]; then
  write_error "No credentials found. Run: python3 ~/.config/omarchy/plugins/nichovski.spotify/setup.py" 3600
fi

NOW=$(now)

# Inside a rate-limit / back-off window? Do not touch the API at all.
if [[ -f "$OUTPUT_FILE" ]]; then
  RETRY_AT=$(jq -r '.retry_at // 0' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  if [[ "$RETRY_AT" =~ ^[0-9]+$ ]] && (( RETRY_AT > NOW )); then
    exit 0
  fi
fi

# --- Currently playing ---
CUR=$(api_call now-playing)
CUR_STATUS=$(jq -r '.status // 0' <<<"$CUR" 2>/dev/null || echo 0)
CUR_ERROR=$(jq -r '.error // empty' <<<"$CUR" 2>/dev/null || true)
CUR_RETRY=$(jq -r '.retry_after // 0' <<<"$CUR" 2>/dev/null || echo 0)
BODY=$(jq -c '.body // null' <<<"$CUR" 2>/dev/null || echo null)

if [[ "$CUR_STATUS" == "429" ]]; then
  [[ "$CUR_RETRY" =~ ^[0-9]+$ ]] || CUR_RETRY=$DEFAULT_RETRY
  (( CUR_RETRY > 0 )) || CUR_RETRY=$DEFAULT_RETRY
  write_rate_limited "$CUR_RETRY"
fi

if [[ "$CUR_STATUS" == "0" || -n "$CUR_ERROR" ]]; then
  write_error "${CUR_ERROR:-Spotify API request failed}"
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

# --- Refresh devices only when the cache is stale ---
if (( DEVICES_FETCHED_AT == 0 )); then
  DEV=$(api_call devices)
  DEV_STATUS=$(jq -r '.status // 0' <<<"$DEV" 2>/dev/null || echo 0)
  DEV_RETRY=$(jq -r '.retry_after // 0' <<<"$DEV" 2>/dev/null || echo 0)
  if [[ "$DEV_STATUS" == "429" ]]; then
    [[ "$DEV_RETRY" =~ ^[0-9]+$ ]] || DEV_RETRY=$DEFAULT_RETRY
    (( DEV_RETRY > 0 )) || DEV_RETRY=$DEFAULT_RETRY
    write_rate_limited "$DEV_RETRY"
  fi
  if [[ "$DEV_STATUS" == "200" ]]; then
    DEVICES_LIST=$(jq -c '[.body.devices // [] | .[] | {id, name, type, is_active}]' <<<"$DEV" 2>/dev/null || echo '[]')
    DEVICES_FETCHED_AT=$NOW
  fi
fi

# --- Nothing currently playing ---
if [[ "$CUR_STATUS" == "204" || "$BODY" == "null" ]]; then
  write_state "$(jq -n --argjson devices "$DEVICES_LIST" --argjson fetched "$DEVICES_FETCHED_AT" '{
    is_playing: false,
    devices: $devices,
    devices_fetched_at: $fetched
  }')"
  exit 0
fi

if [[ "$CUR_STATUS" != "200" ]]; then
  write_error "Spotify API error (HTTP $CUR_STATUS)"
fi

# --- Playing: build output in one pass ---
write_state "$(jq --argjson devices "$DEVICES_LIST" --argjson fetched "$DEVICES_FETCHED_AT" '{
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
}' <<<"$BODY")"