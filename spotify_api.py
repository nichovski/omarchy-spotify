#!/usr/bin/env python3
"""
Minimal Spotify Web API client for the Omarchy Spotify Mini Player plugin.

All HTTP goes through here so the shell scripts never pass a credential on a
command line. Credentials are read from ``credentials.env``; the refresh token
is used only inside a request body, and the bearer token only inside an
Authorization header. Every request is bounded by an explicit connect timeout
and an overall deadline, and the response body is streamed under a hard byte
cap. Exceeding the cap fails closed: the body is discarded and never parsed.

Prints one JSON envelope per run:

    {"status": <int>, "body": <parsed JSON or null>,
     "retry_after": <int or null>, "error": <string or null>}

``status`` is 0 when no HTTP response was obtained (transport or cap failure).
"""

import base64
import http.client
import json
import os
import sys
import time
import urllib.parse
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "omarchy" / "spotify"
CREDENTIALS_FILE = CONFIG_DIR / "credentials.env"
TOKEN_FILE = CONFIG_DIR / "token.json"

ACCOUNTS_HOST = "accounts.spotify.com"
API_HOST = "api.spotify.com"

CONNECT_TIMEOUT = 5.0        # seconds to establish a connection
READ_TIMEOUT = 5.0           # per-read socket timeout
TOTAL_DEADLINE = 10.0        # overall seconds allowed for one request
MAX_RESPONSE_BYTES = 262144  # 256 KiB hard cap on a response body
CHUNK = 65536

CONTROL = {
    "play": ("PUT", "/v1/me/player/play"),
    "pause": ("PUT", "/v1/me/player/pause"),
    "next": ("POST", "/v1/me/player/next"),
    "previous": ("POST", "/v1/me/player/previous"),
}


class ApiError(Exception):
    """Any failure that should be reported to the caller as an error envelope."""


class RateLimited(Exception):
    """The API answered 429; carries the Retry-After value if present."""

    def __init__(self, retry_after):
        super().__init__("rate limited")
        self.retry_after = retry_after


def load_credentials():
    try:
        text = CREDENTIALS_FILE.read_text()
    except OSError as exc:
        raise ApiError("no credentials found") from exc

    creds = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        creds[key.strip()] = value.strip()

    if not (creds.get("SPOTIFY_CLIENT_ID") and creds.get("SPOTIFY_REFRESH_TOKEN")):
        raise ApiError("incomplete credentials")
    return creds


def load_cached_token():
    try:
        data = json.loads(TOKEN_FILE.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    token = data.get("access_token")
    expires_at = data.get("expires_at")
    if not token or not isinstance(expires_at, (int, float)):
        return None
    if expires_at <= time.time() + 30:
        return None
    return token


def save_cached_token(token, expires_at):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = TOKEN_FILE.with_name(TOKEN_FILE.name + ".tmp")
    tmp.write_text(json.dumps({"access_token": token, "expires_at": expires_at}))
    os.chmod(tmp, 0o600)
    tmp.replace(TOKEN_FILE)


def http_request(method, host, path, headers=None, body=None):
    """One bounded HTTPS request. Returns (status, retry_after, raw_body)."""
    deadline = time.monotonic() + TOTAL_DEADLINE
    conn = http.client.HTTPSConnection(host, timeout=CONNECT_TIMEOUT)
    try:
        conn.putrequest(method, path)
        for key, value in (headers or {}).items():
            conn.putheader(key, value)
        if body is not None:
            conn.putheader("Content-Length", str(len(body)))
        conn.endheaders(body)

        resp = conn.getresponse()
        if time.monotonic() > deadline:
            raise ApiError("total deadline exceeded")
        status = resp.status
        retry_after = resp.getheader("Retry-After")

        chunks = []
        total = 0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ApiError("total deadline exceeded")
            if conn.sock is not None:
                conn.sock.settimeout(min(READ_TIMEOUT, remaining))
            chunk = resp.read(CHUNK)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_RESPONSE_BYTES:
                raise ApiError("response exceeds %d bytes" % MAX_RESPONSE_BYTES)
            chunks.append(chunk)

        return status, retry_after, b"".join(chunks)
    except (http.client.HTTPException, OSError) as exc:
        raise ApiError(str(exc) or exc.__class__.__name__) from exc
    finally:
        conn.close()


def refresh_access_token(creds):
    body = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": creds["SPOTIFY_REFRESH_TOKEN"],
    }).encode("ascii")
    auth = base64.b64encode(
        ("%s:%s" % (creds.get("SPOTIFY_CLIENT_ID", ""),
                    creds.get("SPOTIFY_CLIENT_SECRET", ""))).encode()
    ).decode("ascii")
    headers = {
        "Authorization": "Basic " + auth,
        "Content-Type": "application/x-www-form-urlencoded",
    }
    return http_request("POST", ACCOUNTS_HOST, "/api/token", headers=headers, body=body)


def access_token():
    token = load_cached_token()
    if token:
        return token

    status, retry_after, raw = refresh_access_token(load_credentials())
    if status == 429:
        raise RateLimited(retry_after)
    if status != 200:
        raise ApiError("token refresh failed (HTTP %s)" % status)

    try:
        data = json.loads(raw)
    except ValueError as exc:
        raise ApiError("invalid token response") from exc

    token = data.get("access_token")
    if not token:
        raise ApiError("token response had no access_token")
    try:
        expires_in = int(data.get("expires_in", 3600))
    except (TypeError, ValueError):
        expires_in = 3600
    save_cached_token(token, time.time() + expires_in)
    return token


def api_request(method, path, token, headers=None, body=None):
    merged = {"Authorization": "Bearer " + token}
    if headers:
        merged.update(headers)
    status, retry_after, raw = http_request(method, API_HOST, path,
                                            headers=merged, body=body)
    if status == 429:
        raise RateLimited(retry_after)

    parsed = None
    if raw:
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = None
    return status, parsed


def envelope(status, body=None, retry_after=None, error=None):
    return {"status": status, "body": body,
            "retry_after": retry_after, "error": error}


def cmd_now_playing():
    status, body = api_request(
        "GET", "/v1/me/player/currently-playing", access_token())
    return envelope(status, body=body)


def cmd_devices():
    status, body = api_request("GET", "/v1/me/player/devices", access_token())
    return envelope(status, body=body)


def cmd_control(action):
    if action not in CONTROL:
        raise ApiError("unknown control action: %s" % action)
    method, path = CONTROL[action]
    status, _ = api_request(method, path, access_token())
    return envelope(status)


def cmd_transfer(device_id):
    if not device_id:
        raise ApiError("missing device id")
    body = json.dumps({"device_ids": [device_id], "play": True}).encode()
    status, _ = api_request(
        "PUT", "/v1/me/player", access_token(),
        headers={"Content-Type": "application/json"}, body=body)
    return envelope(status)


def parse_retry(value):
    try:
        seconds = int(value)
    except (TypeError, ValueError):
        return None
    return seconds if seconds > 0 else None


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(
            "usage: spotify_api.py <now-playing|devices|control|transfer> [arg]\n")
        return 2

    command = argv[1]
    arg = argv[2] if len(argv) > 2 else ""
    try:
        if command == "now-playing":
            result = cmd_now_playing()
        elif command == "devices":
            result = cmd_devices()
        elif command == "control":
            result = cmd_control(arg)
        elif command == "transfer":
            result = cmd_transfer(arg)
        else:
            raise ApiError("unknown command: %s" % command)
    except RateLimited as exc:
        result = envelope(429, retry_after=parse_retry(exc.retry_after),
                          error="rate limited")
    except ApiError as exc:
        result = envelope(0, error=str(exc))

    sys.stdout.write(json.dumps(result) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))