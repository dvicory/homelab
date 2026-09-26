#!/usr/bin/env python3
"""Jellyfin application smoke behavior for the replacement acceptance test.

Only Jellyfin HTTP API behavior lives here: authentication, setup-boundary,
library observation, playback-state verification, and media retrieval. No
Incus, Kubernetes, Argo, storage mounts, or compute lifecycle.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request


def authorization(token: str | None = None) -> str:
    # Jellyfin 12 rejects the legacy X-Emby-Authorization/X-MediaBrowser-Token
    # headers on fresh installs; client identity and token share one header.
    value = 'MediaBrowser Client="homelab-smoke", Device="integration", DeviceId="homelab-smoke", Version="1.0"'
    return value + (f', Token="{token}"' if token is not None else "")


def api_request(
    base: str,
    method: str,
    path: str,
    *,
    token: str | None = None,
    payload=None,
    expected: tuple[int, ...] = (200,),
    read_body: bool = True,
):
    headers = {
        "Accept": "application/json",
        "Authorization": authorization(token),
    }
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            status = response.status
            body = response.read() if read_body else b""
    except urllib.error.HTTPError as error:
        status, body = error.code, error.read() if read_body else b""
    if status not in expected:
        raise AssertionError(f"{method} {path}: expected {expected}, got {status}: {body[:200]!r}")
    if not read_body or not body:
        return status, None
    return status, json.loads(body)


def api_bytes(base: str, path: str, token: str) -> bytes:
    headers = {"Authorization": authorization(token)}
    request = urllib.request.Request(base + path, headers=headers, method="GET")
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.status != 200:
            raise AssertionError(f"GET {path}: expected 200, got {response.status}")
        return response.read()


def verify_setup_closed(base: str) -> None:
    """A provisioned server must not expose the first-run enrollment API."""
    for path in ("/Startup/Configuration", "/Startup/User"):
        api_request(base, "GET", path, expected=(401, 404), read_body=False)


def authenticate(base: str, username: str, password: str) -> tuple[str, str]:
    _, auth = api_request(base, "POST", "/Users/AuthenticateByName", payload={"Username": username, "Pw": password}, expected=(200,))
    return auth["AccessToken"], auth["User"]["Id"]


def verify_library(base: str, token: str, name: str = "Movies", path: str = "/media") -> None:
    _, folders = api_request(base, "GET", "/Library/VirtualFolders", token=token, expected=(200,))
    folder = next((folder for folder in folders if folder.get("Name") == name), None)
    assert folder is not None and path in folder.get("Locations", []), f"Jellyfin retains the {name} library at {path}"

def find_media(base: str, token: str, user_id: str, suffix: str = "recovery.mkv") -> dict | None:
    """Locate the fixture media indexed under the Jellarr-owned library."""
    query = urllib.parse.urlencode({"Recursive": "true", "IncludeItemTypes": "Movie", "Fields": "Path,MediaSources,UserData"})
    _, result = api_request(base, "GET", f"/Users/{user_id}/Items?{query}", token=token, expected=(200,))
    return next((item for item in result.get("Items", []) if item.get("Path", "").endswith(suffix)), None)


def set_played(base: str, token: str, user_id: str, item_id: str, played: bool) -> None:
    method = "POST" if played else "DELETE"
    api_request(base, method, f"/Users/{user_id}/PlayedItems/{item_id}", token=token, expected=(204, 200))


def is_played(base: str, token: str, user_id: str, item_id: str) -> bool:
    _, item = api_request(base, "GET", f"/Users/{user_id}/Items/{item_id}?Fields=Path,UserData", token=token, expected=(200,))
    return item.get("UserData", {}).get("Played") is True


def verify_state(base: str, username: str, password: str, library: str, item_id: str) -> tuple[str, str]:
    """Verify retained access, library, item, playback state, and media bytes."""
    verify_setup_closed(base)
    token, user_id = authenticate(base, username, password)
    verify_library(base, token, library)
    _, item = api_request(base, "GET", f"/Users/{user_id}/Items/{item_id}?Fields=Path,UserData", token=token, expected=(200,))
    assert item.get("Path", "").endswith("recovery.mkv"), "replacement retains the indexed media item"
    assert item.get("UserData", {}).get("Played") is True, "replacement retains the recorded playback state"
    body = api_bytes(base, f"/Videos/{item_id}/stream?static=true", token)
    assert body.startswith(b"\x1a\x45\xdf\xa3"), "authorized client consumes the retained media bytes"
    return token, user_id
