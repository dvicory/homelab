#!/usr/bin/env python3
"""Jellyfin application smoke behavior for the replacement acceptance test.

Only Jellyfin HTTP API behavior lives here: first-run setup, authentication,
library observation, playback-state verification, and media retrieval. No
Incus, Kubernetes, Argo, storage mounts, or compute lifecycle.
"""

from __future__ import annotations

import json
import secrets
import urllib.error
import urllib.parse
import urllib.request


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
        "X-Emby-Authorization": 'MediaBrowser Client="homelab-smoke", Device="integration", '
        'DeviceId="homelab-smoke", Version="1.0"',
    }
    if token is not None:
        headers["X-MediaBrowser-Token"] = token
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
    headers = {
        "X-MediaBrowser-Token": token,
        "X-Emby-Authorization": 'MediaBrowser Client="homelab-smoke", Device="integration", '
        'DeviceId="homelab-smoke", Version="1.0"',
    }
    request = urllib.request.Request(base + path, headers=headers, method="GET")
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.status != 200:
            raise AssertionError(f"GET {path}: expected 200, got {response.status}")
        return response.read()


def setup_first_run(base: str) -> tuple[str, str]:
    """Complete Jellyfin native first-run enrollment; return (username, password)."""
    username = "recovery-admin"
    password = secrets.token_urlsafe(24)
    api_request(
        base,
        "POST",
        "/Startup/Configuration",
        payload={
            "ServerName": "compute-recovery",
            "UICulture": "en-US",
            "MetadataCountryCode": "US",
            "PreferredMetadataLanguage": "en",
        },
        expected=(204, 200),
    )
    api_request(base, "GET", "/Startup/User", expected=(200,))
    api_request(base, "POST", "/Startup/User", payload={"Name": username, "Password": password}, expected=(204, 200))
    api_request(
        base, "POST", "/Startup/RemoteAccess", payload={"EnableRemoteAccess": False, "EnableAutomaticPortMapping": False}, expected=(204, 200)
    )
    api_request(base, "POST", "/Startup/Complete", payload={}, expected=(204, 200))
    return username, password


def authenticate(base: str, username: str, password: str) -> tuple[str, str]:
    _, auth = api_request(base, "POST", "/Users/AuthenticateByName", payload={"Username": username, "Pw": password}, expected=(200,))
    return auth["AccessToken"], auth["User"]["Id"]


def ensure_music_library(base: str, token: str, name: str = "Recovery Media", path: str = "/media") -> None:
    query = urllib.parse.urlencode({"name": name, "collectionType": "music", "refreshLibrary": "true"})
    api_request(
        base, "POST", f"/Library/VirtualFolders?{query}", token=token, payload={"LibraryOptions": {"PathInfos": [{"Path": path}]}}, expected=(204, 200)
    )


def find_audio(base: str, token: str, user_id: str, suffix: str = "recovery.wav") -> dict | None:
    query = urllib.parse.urlencode({"Recursive": "true", "IncludeItemTypes": "Audio", "Fields": "Path,MediaSources,UserData"})
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
    token, user_id = authenticate(base, username, password)
    status, _ = api_request(base, "GET", "/Startup/Configuration", expected=tuple(range(400, 600)))
    assert 400 <= status < 600, "replacement must not re-expose the Jellyfin setup endpoint"
    _, folders = api_request(base, "GET", "/Library/VirtualFolders", token=token, expected=(200,))
    folder = next((f for f in folders if f.get("Name") == library), None)
    assert folder is not None and "/media" in folder.get("Locations", []), "replacement retains the configured Jellyfin library"
    _, item = api_request(base, "GET", f"/Users/{user_id}/Items/{item_id}?Fields=Path,UserData", token=token, expected=(200,))
    assert item.get("Path", "").endswith("recovery.wav"), "replacement retains the indexed media item"
    assert item.get("UserData", {}).get("Played") is True, "replacement retains the recorded playback state"
    body = api_bytes(base, f"/Audio/{item_id}/stream?static=true", token)
    assert body.startswith(b"RIFF") and body[8:12] == b"WAVE", "authorized client consumes the retained media bytes"
    return token, user_id
