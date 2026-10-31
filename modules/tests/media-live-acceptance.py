#!/usr/bin/env python3
"""Pinned native media API acceptance, using only owned Docker Linux volumes.

Requires Python/PyYAML, openssl, Docker Engine 26+ (volume-subpath), and an
explicit local unix Docker socket. Default linux/amd64 matches production;
Docker Desktop/emulation does not prove the Incus/MergerFS/host storage seam.
The synthetic HTTPS Secret responder tests bootstrap transport, NOT K8s RBAC.
"""
import argparse
import base64
from copy import deepcopy
from functools import partial
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit

import yaml

ROOT = Path(__file__).resolve().parents[2]
MANIFESTS = ROOT / "generated/manifests/prod-home"


def require(condition, label):
    if not condition:
        raise AssertionError(label)


def require_application_exit(status, failure, label):
    expected = 1 if failure else 0
    require(status == expected, f"{label} (exit {status}, expected {expected})")


def require_container_exit(result, failure, name):
    # Only the initial setup fixture reports Docker startup errors.
    if name == "fixture" and result.returncode and result.stderr:
        # Escape controls before bounding the diagnostic, including its marker.
        output = json.dumps(result.stderr, ensure_ascii=True)
        if len(output) > 2048:
            output = output[:2034] + "...[truncated]"
        print(f"media-live-acceptance: fixture startup stderr: {output}", file=sys.stderr)
    require_application_exit(result.returncode, failure, name)


def command(*args, timeout=60, env=None):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout, env=env)
    # Do not leak generated credentials or application output on failure.
    require(result.returncode == 0, f"{args[0]} command failed (exit {result.returncode})")
    return result.stdout.strip()


def manifest(group, name):
    return yaml.safe_load((MANIFESTS / group / name).read_text())


def pod(group, name):
    return manifest(group, name)["spec"]["template"]["spec"]


def request_from_container(docker, client, endpoint, path, *, key=None, method="GET", body=None, jellyfin=False, binary=False):
    headers = {"Content-Type": "application/json"}
    if key:
        headers["X-Api-Key"] = key
    if jellyfin:
        headers["Authorization"] = (
            'MediaBrowser Client="homelab-acceptance", Device="Fixture", DeviceId="fixture", Version="1"'
            + (f', Token="{key}"' if key else "")
        )
        headers.pop("X-Api-Key", None)
    # Keep the application network internal: Docker does not publish its ports.
    result = json.loads(docker("exec", client, "/lsiopy/bin/python", "-c", '''
import base64, json, sys
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener
value = json.loads(sys.argv[1])
payload = json.dumps(value["body"]).encode() if value["body"] is not None else None
try:
    try:
        response = build_opener(ProxyHandler({})).open(
            Request(value["url"], payload, value["headers"], method=value["method"]), timeout=15)
    except HTTPError as error:
        response = error
    with response:
        print(json.dumps({"status": response.status, "body": base64.b64encode(response.read()).decode()}))
except (URLError, OSError):
    print(json.dumps({"transportError": True}))
''', json.dumps({"url": f"http://{endpoint}{path}", "headers": headers, "method": method, "body": body})))
    if result.get("transportError"):
        raise OSError("isolated native API transport unavailable")
    if result["status"] >= 400:
        raise HTTPError("http://fixture", result["status"], "native API refused request", {}, None)
    raw = base64.b64decode(result["body"])
    return raw if binary else (json.loads(raw) if raw else None)


def page_from_container(docker, client, endpoint, path, headers):
    """GET a browser page without following redirects; return status, Location and body."""
    result = json.loads(docker("exec", client, "/lsiopy/bin/python", "-c", '''
import base64, json, sys
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
class Keep(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None
value = json.loads(sys.argv[1])
try:
    try:
        response = build_opener(ProxyHandler({}), Keep()).open(Request(value["url"], headers=value["headers"]), timeout=15)
    except HTTPError as error:
        response = error
    with response:
        print(json.dumps({"status": response.status, "location": response.headers.get("Location"),
                          "body": base64.b64encode(response.read()).decode()}))
except (URLError, OSError):
    print(json.dumps({"transportError": True}))
''', json.dumps({"url": f"http://{endpoint}{path}", "headers": headers})))
    if result.get("transportError"):
        raise OSError("isolated browser transport unavailable")
    result["body"] = base64.b64decode(result["body"])
    return result


def ready(request, port, path, *, key=None):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            return request(port, path, key=key)
        except HTTPError as error:
            require(error.code >= 500, f"readiness returned HTTP {error.code}")
        except OSError:
            pass
        time.sleep(1)
    raise AssertionError("native API readiness deadline exceeded")


def denied(call, statuses=(401, 403)):
    try:
        call()
    except HTTPError as error:
        require(error.code in statuses, f"unexpected refusal HTTP {error.code}")
        return
    raise AssertionError("native API accepted a forbidden operation")


def rejected(check, label):
    try:
        check()
    except AssertionError:
        return
    raise AssertionError(label + " mutation was not detected")


def one(items, field, value):
    found = [item for item in items if item[field] == value]
    require(len(found) == 1, f"missing or ambiguous native {field}: {value}")
    return found[0]


def fields(item):
    return {field["name"]: field.get("value") for field in item["fields"]}


def specifications(items):
    return sorted((item["name"], item["implementation"], item.get("negate", False),
                   item.get("required", False), json.dumps(
                       fields(item) if isinstance(item["fields"], list) else item["fields"], sort_keys=True))
                  for item in items)


def profile_expectations(configuration, upstream, formats, definitions, app, instance):
    class ConfigarrLoader(yaml.SafeLoader):
        pass

    ConfigarrLoader.add_constructor("!env", lambda loader, node: loader.construct_scalar(node))
    source = yaml.load(configuration, Loader=ConfigarrLoader)[app][instance]
    renames = {item["from"]: item["to"] for item in source.get("renameQualityProfiles", [])}
    overrides = {item["name"]: item for item in source["quality_profiles"]}
    profiles = {}
    for include in source["include"]:
        item = upstream[include["template"]]
        name = renames.get(item["name"], item["name"])
        override = overrides[name]
        qualities = override.get("qualities", [
            {"name": quality["name"], "qualities": quality.get("items", [])}
            for quality in item["items"] if quality["allowed"]
        ])
        configured = {leaf for quality in qualities for leaf in quality.get("qualities") or [quality["name"]]}
        profiles[name] = {
            "name": name,
            "upgradeAllowed": item["upgradeAllowed"],
            "cutoff": override["upgrade"].get("until_quality", item["cutoff"]),
            "minFormatScore": item["minFormatScore"],
            "cutoffFormatScore": item["cutoffFormatScore"],
            "minUpgradeFormatScore": override["upgrade"]["min_format_score"],
            "items": [
                {"name": quality["name"], "allowed": quality.get("enabled", True), "items": quality.get("qualities", [])}
                for quality in qualities
            ] + [
                {"name": quality["quality"]["name"], "allowed": False, "items": []}
                for quality in definitions if quality["quality"]["name"] not in configured
            ],
            "formatScores": {trash_id: formats[trash_id]["trash_scores"]["default"] for trash_id in item["formatItems"].values()},
            **({"language": item["language"]} if "language" in item else {}),
        }
    for group in source["custom_formats"]:
        for assignment in group["assign_scores_to"]:
            for trash_id in group["trash_ids"]:
                score = (formats[trash_id]["trash_scores"]["default"]
                         if assignment.get("use_default_score") else assignment["score"])
                profiles[assignment["name"]]["formatScores"][trash_id] = score
    return profiles


def verify_profile(api, desired, formats):
    profile = one(api("/qualityprofile"), "name", desired["name"])
    for key in ("upgradeAllowed", "minFormatScore", "cutoffFormatScore", "minUpgradeFormatScore"):
        require(profile[key] == desired[key], "native quality profile differs: " + key)
    if "language" in desired:
        require(profile["language"]["name"] == desired["language"], "native profile language differs")
    cutoffs = [item for item in profile["items"] if item.get("id", item.get("quality", {}).get("id")) == profile["cutoff"]]
    require(len(cutoffs) == 1, "native quality cutoff identity is missing or ambiguous")
    cutoff = cutoffs[0]
    require((cutoff.get("name") or cutoff.get("quality", {}).get("name")) == desired["cutoff"], "native quality cutoff differs")
    actual_qualities = {}
    for item in profile["items"]:
        name = item.get("name") or item.get("quality", {}).get("name")
        actual_qualities[name] = (item["allowed"], sorted(child["quality"]["name"] for child in item.get("items", [])))
    expected_qualities = {item["name"]: (item["allowed"], sorted(item.get("items", []))) for item in desired["items"]}
    if actual_qualities != expected_qualities:
        differences = {
            name: {"actual": actual_qualities.get(name), "expected": expected_qualities.get(name)}
            for name in sorted(actual_qualities.keys() | expected_qualities.keys())
            if actual_qualities.get(name) != expected_qualities.get(name)
        }
        detail = {"profile": desired["name"], "qualities": differences}
        prefix = "native allowed qualities/group membership differ: "
        diagnostic = prefix + json.dumps(detail, ensure_ascii=True, sort_keys=True)
        if len(diagnostic) > 4000:
            first = next(iter(differences))
            detail["qualities"] = {first: differences[first]}
            detail["omittedQualityCount"] = len(differences) - 1
            diagnostic = prefix + json.dumps(detail, ensure_ascii=True, sort_keys=True)
        raise AssertionError(diagnostic)
    actual_formats = api("/customformat")
    scores = {item["format"]: item["score"] for item in profile["formatItems"]}
    identities = {}
    for trash_id, expected in formats.items():
        name = expected["name"]
        # Formats shared by several profiles still have one native identity;
        # formats owned only by another profile must retain score zero here.
        if not any(item["name"] == name for item in actual_formats):
            require(trash_id not in desired["formatScores"], "native custom format is missing: " + name)
            continue
        actual = one(actual_formats, "name", name)
        require(actual["includeCustomFormatWhenRenaming"] == expected["includeCustomFormatWhenRenaming"], "native custom format rename behavior differs")
        require(specifications(actual["specifications"]) == specifications(expected["specifications"]), "native custom format identity/specifications differ: " + name)
        require(scores.get(actual["id"]) == desired["formatScores"].get(trash_id, 0), "native custom format score differs: " + desired["name"] + " / " + name)
        identities[trash_id] = actual["id"]
    return profile["id"], identities


def verify_hd_menu(api, app):
    profiles = api("/qualityprofile")
    menu = {
        "preferred": one(profiles, "name", "HD Preferred"),
        "web": one(profiles, "name", "WEB 1080p" if app == "radarr" else "WEB-1080p"),
        "remux": one(profiles, "name", "Remux + WEB 1080p"),
    }
    remux = "Remux-1080p" if app == "radarr" else "Bluray-1080p Remux"
    cases = [
        ("1080p.WEB-DL.DDP5.1.H.264", "WEBDL-1080p", {"preferred", "web", "remux"}),
        ("1080p.WEBRip.DDP5.1.x264", "WEBRip-1080p", {"preferred", "web", "remux"}),
        ("1080p.BluRay.DTS.x264", "Bluray-1080p", {"preferred"}),
        ("1080p.HDTV.x264", "HDTV-1080p", {"preferred"}),
        ("720p.BluRay.DTS.x264", "Bluray-720p", {"preferred"}),
        ("720p.WEB-DL.AAC2.0.H.264", "WEBDL-720p", {"preferred"}),
        ("720p.WEBRip.AAC2.0.x264", "WEBRip-720p", {"preferred"}),
        ("720p.HDTV.x264", "HDTV-720p", {"preferred"}),
        ("480p.DVDRip.x264", "DVD", {"preferred"}),
        ("480p.WEB-DL.AAC2.0.H.264", "WEBDL-480p", {"preferred"}),
        ("480p.WEBRip.AAC2.0.x264", "WEBRip-480p", {"preferred"}),
        ("480p.SDTV.x264", "SDTV", {"preferred"}),
        ("1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1", remux, {"remux"}),
        ("2160p.WEB-DL.DDP5.1.H.265", "WEBDL-2160p", set()),
        ("2160p.WEBRip.DDP5.1.x265", "WEBRip-2160p", set()),
        ("2160p.BluRay.DTS.x265", "Bluray-2160p", set()),
        ("2160p.BluRay.REMUX.HEVC.DTS-HD.MA.5.1",
         "Remux-2160p" if app == "radarr" else "Bluray-2160p Remux", set()),
        ("2160p.HDTV.H.265", "HDTV-2160p", set()),
    ]
    for role, profile in menu.items():
        allowed = {leaf["quality"]["name"]
                   for item in profile["items"] if item["allowed"]
                   for leaf in (item.get("items") or [item])}
        expected = {quality for _, quality, wanted in cases if role in wanted}
        require(allowed == expected, app + " native allowed-quality set differs: " + role)
    preferred = menu["preferred"]
    positions = {leaf["quality"]["name"]: rank
                 for rank, item in enumerate(preferred["items"])
                 for leaf in (item.get("items") or [item])}
    bands = (
        {"SDTV"},
        {"DVD", "WEBDL-480p", "WEBRip-480p"},
        {"Bluray-720p", "WEBDL-720p", "WEBRip-720p", "HDTV-720p"},
        {"Bluray-1080p", "WEBDL-1080p", "WEBRip-1080p", "HDTV-1080p"},
    )
    for lower, higher in zip(bands, bands[1:]):
        require(max(positions[name] for name in lower) < min(positions[name] for name in higher),
                app + " native preferred-quality priority bands differ")
    cutoff = next(item for item in preferred["items"]
                  if item.get("id", item.get("quality", {}).get("id")) == preferred["cutoff"])
    cutoff_members = {leaf["quality"]["name"] for leaf in (cutoff.get("items") or [cutoff])}
    require(preferred["upgradeAllowed"] and cutoff_members <= bands[-1] and cutoff["allowed"],
            app + " native preferred upgrade target is not enabled 1080p")
    for suffix, quality, wanted in cases:
        title = ("Fixture.Movie.2024." if app == "radarr" else "Fixture.Series.S01E01.") + suffix + "-Fixture"
        parsed = api("/parse?" + urlencode({"title": title}))
        info = parsed["parsedMovieInfo" if app == "radarr" else "parsedEpisodeInfo"]
        require(info["quality"]["quality"]["name"] == quality, app + " native parser classified release unexpectedly")
        # This checks the persisted native quality gate, not a complete download
        # decision: /parse cannot evaluate a profile without a catalogue item.
        for role, profile in menu.items():
            items = [item for item in profile["items"]
                     if item.get("quality", {}).get("name") == quality or
                     any(child["quality"]["name"] == quality for child in item.get("items", []))]
            require(len(items) == 1, app + " native quality is missing or ambiguous: " + quality)
            require(items[0]["allowed"] == (role in wanted), app + " native quality gate differs: " + role + " / " + quality)


def verify_format_policy(api, app, profile_names):
    formats = api("/customformat")
    unwanted = {name: one(formats, "name", name)["id"] for name in ("x265 (HD)", "AV1")}
    profiles = api("/qualityprofile")
    for profile in profiles:
        if profile["name"] in profile_names:
            for name, format_id in unwanted.items():
                require(one(profile["formatItems"], "format", format_id)["score"] == -10000,
                        app + " native unwanted-codec penalty differs: " + profile["name"] + " / " + name)
            # Independent anchors catch per-profile assignment mistakes even
            # when the rendered configuration makes the same mistake.
            scores = {
                "WEB Tier 01": 1700,
                "AMZN": 0 if app == "radarr" else 75,
                "Remux Tier 01": (1950 if app == "radarr" else 1900) if profile["name"] == "Remux + WEB 1080p" else 0,
                **({"HD Bluray Tier 01": 1800 if profile["name"] == "HD Preferred" else 0} if app == "radarr" else {}),
            }
            for name, score in scores.items():
                format_id = one(formats, "name", name)["id"]
                require(one(profile["formatItems"], "format", format_id)["score"] == score,
                        app + " native per-profile tier assignment differs: " + profile["name"] + " / " + name)
    for suffix, matches in (
        ("1080p.BluRay.DTS.x264", set()),
        ("1080p.BluRay.DTS.x265", {"x265 (HD)"}),
        ("1080p.BluRay.DTS.AV1", {"AV1"}),
        ("2160p.BluRay.DTS.x265", set()),
        ("480p.WEB-DL.AAC2.0.H.264", set()),
        ("480p.WEB-DL.AAC2.0.x265", {"x265 (HD)"}),
        ("480p.WEB-DL.AAC2.0.AV1", {"AV1"}),
    ):
        title = ("Fixture.Movie.2024." if app == "radarr" else "Fixture.Series.S01E01.") + suffix + "-Fixture"
        parsed = api("/parse?" + urlencode({"title": title}))
        actual = {item["name"]: item["id"] for item in parsed["customFormats"] if item["name"] in unwanted}
        require(actual == {name: unwanted[name] for name in matches},
                app + " native custom-format matching failed a codec counterfactual")
        if suffix.startswith("480p."):
            preferred = one(profiles, "name", "HD Preferred")
            scores = {item["format"]: item["score"] for item in preferred["formatItems"]}
            # Compose native matched IDs with persisted profile scores, not
            # /parse.customFormatScore: it is not a catalogue-backed decision.
            effective = sum(scores.get(item["id"], 0) for item in parsed["customFormats"])
            require(preferred["minFormatScore"] == 0, app + " native preferred minimum score changed")
            require(effective < preferred["minFormatScore"] if matches else effective == 0,
                    app + " native SD matched-format/profile-score gate differs")


def daemon_identity(docker, container, marker, expected):
    # Read the daemon's /proc status, not the root docker-exec process identity.
    raw = docker("exec", container, "sh", "-ec", '''for p in /proc/[0-9]*; do
      [ -r "$p/cmdline" ] && [ -r "$p/status" ] || continue
      printf '\\nPROCESS\\n'; tr '\\000' ' ' < "$p/cmdline" || continue; printf '\\n'; cat "$p/status" || true
    done''')
    matches = []
    for block in ("\n" + raw).split("\nPROCESS\n"):
        lines = block.splitlines()
        if not lines or marker not in lines[0] or lines[0].startswith("sh -ec"):
            continue
        status = dict(line.split(":", 1) for line in lines[1:] if ":" in line)
        name = status.get("Name", "").strip()
        # s6-notifyoncheck repeats the daemon's argv, and its readiness poller
        # can outlive the first successful API request. The kernel truncates
        # its Name to "s6-notifyonchec".
        if name.startswith("s6-"):
            continue
        if not marker.endswith(".py") and name != Path(marker).name:
            continue
        if "Uid" in status:
            matches.append((lines[0], tuple(map(int, status["Uid"].split())), tuple(map(int, status["Gid"].split())), set(map(int, status["Groups"].split()))))
    require(len(matches) == 1, f"cannot uniquely identify actual {marker} daemon: {[match[0] for match in matches]}")
    _, uid, gid, groups = matches[0]
    require(set(uid) == {expected[0]} and set(gid) == {expected[1]}, f"{marker} daemon UID/GID differs: {uid}/{gid}")
    require(set(expected[2]) <= groups, f"{marker} daemon loses declared supplemental groups: actual={sorted(groups)}, required={expected[2]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker-host", required=True, help="explicit local unix:// Docker socket")
    parser.add_argument("--platform", default="linux/amd64", choices=("linux/amd64", "linux/arm64"))
    parser.add_argument("--seerr-phases", required=True, type=Path, help="Nix-rendered initial and ready Seerr Jobs")
    args = parser.parse_args()
    require(args.docker_host.startswith("unix:///") and Path(args.docker_host[7:]).is_socket(), "only an existing explicit local Unix Docker socket is allowed")
    require(not os.environ.get("PYTHONOPTIMIZE"), "acceptance cannot run with Python optimization")
    for executable in ("docker", "openssl"):
        require(shutil.which(executable), executable + " is required")
    docker_env = {key: value for key, value in os.environ.items() if key not in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH")}
    docker_prefix = ("docker", "--host", args.docker_host)
    docker = lambda *items, **kwargs: command(*docker_prefix, *items, env=docker_env, **kwargs)
    server = json.loads(docker("version", "--format", "{{json .Server}}"))
    require(tuple(map(int, server["ApiVersion"].split("."))) >= (1, 45), "Docker API 1.45+ is required for Linux volume subpaths")
    cm = manifest("media-configuration", "ConfigMap-media-configuration.yaml")["data"]
    policy = json.loads(cm["seerr.json"])
    configarr_pod = pod("media-configuration", "Job-media-configarr.yaml")
    configarr = one(configarr_pod["containers"], "name", "configarr")
    periodic_configarr_pod = manifest("media-configuration", "CronJob-media-configarr.yaml")["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    periodic_configarr = one(periodic_configarr_pod["containers"], "name", "configarr")
    seerr_phases = json.loads(args.seerr_phases.read_text())
    initial_job = seerr_phases["initial"]["spec"]
    initial_pod = initial_job["template"]["spec"]
    initial_configure = one(initial_pod["containers"], "name", "configure")
    seerr_job = seerr_phases["ready"]["spec"]
    seerr_pod = seerr_job["template"]["spec"]
    configure = one(seerr_pod["containers"], "name", "configure")
    periodic_job = manifest("media-configuration", "CronJob-media-config-seerr.yaml")["spec"]["jobTemplate"]["spec"]
    periodic_pod = periodic_job["template"]["spec"]
    periodic_configure = one(periodic_pod["containers"], "name", "configure")
    pods = {app: pod(app, f"Deployment-{app}.yaml") for app in ("radarr", "sonarr", "prowlarr", "sabnzbd", "jellyfin")}
    pods["seerr"] = pod("seerr", "StatefulSet-seerr.yaml")
    apps = {app: one(value["containers"], "name", "jellyfin" if app == "jellyfin" else "main") for app, value in pods.items()}
    for container in (*apps.values(), configarr, initial_configure, configure, periodic_configure):
        require("@sha256:" in container["image"], "native scenario requires digest-pinned images")
    identities = {}
    for app, container in apps.items():
        declared = {item["name"]: item["value"] for item in container.get("env", []) if "value" in item}
        security = {**pods[app].get("securityContext", {}), **container.get("securityContext", {})}
        identities[app] = (int(security.get("runAsUser", declared.get("PUID", 0))), int(security.get("runAsGroup", declared.get("PGID", 0))), security.get("supplementalGroups", []))
    media_gid, = identities["radarr"][2]
    for app in ("sonarr", "sabnzbd"):
        require(identities[app][2] == [media_gid], "shared media group declarations differ")
    require(identities["jellyfin"][2] == [media_gid, 506], "Jellyfin holds media and its gpu-render accelerator grant")
    policy_source = json.loads((ROOT / "assets/media-policy/source.json").read_text())
    required_formats = json.loads((ROOT / "assets/media-policy/required-formats.json").read_text())
    cache_root = one(configarr["env"], "name", "CUSTOM_REPO_ROOT")["value"]
    # Immutable parent of the compatible template pin; that commit changes only
    # a CI action, so both revisions retain the native legacy includes layout.
    # https://github.com/recyclarr/config-templates/commit/4ae377bb704fc7fd69a544ad04e91357e0b09f62
    previous_template_revision = "86bed2fded1acbe364e165c1d7d60be0d5473e63"
    previous_cache_root = cache_root.replace(policy_source["templateRevision"], previous_template_revision)
    libraries = json.loads(manifest("jellyfin-configuration", "ConfigMap-jellarr-configuration.yaml")["data"]["config.yml"])["library"]["virtualFolders"]
    keys = {app: secrets.token_hex(32) for app in ("radarr", "sonarr", "prowlarr", "seerr")}
    sab_init = pods["sabnzbd"]["initContainers"][0]["command"][-1]
    runtime = {app.upper() + "_API_KEY": value for app, value in keys.items()}
    runtime["SABNZBD_API_KEY"] = secrets.token_hex(32)
    # Each admin app sits behind its Gateway route; its own login is off.
    gateway_hosts = {}
    for app in ("radarr", "sonarr", "prowlarr", "sabnzbd"):
        route = manifest("identity-gateway", f"HTTPRoute-{app}.yaml")["spec"]
        backend, = route["rules"][0]["backendRefs"]
        require((backend["namespace"], backend["name"]) == ("media", app), f"{app} route does not reach the {app} Service")
        require(manifest("identity-gateway", f"SecurityPolicy-{app}-admin.yaml")["spec"]["targetRefs"][0]["name"] == app,
                f"{app} route has no Kanidm sign-in policy")
        gateway_hosts[app] = route["hostnames"][0]
    for name in json.loads(re.search(r"for key in (\[.*?\]):", sab_init).group(1)):
        runtime.setdefault(name, "synthetic-provider-credential")
    network = "homelab-media-live-" + secrets.token_hex(6)
    volume = network + "-fixture"
    source_network = network + "-sources"
    owned_containers = []
    network_created = source_network_created = volume_created = False
    with tempfile.TemporaryDirectory(prefix=network + "-", dir=Path.home()) as directory:
        root = Path(directory)
        try:
            network_created = True
            docker("network", "create", "--internal", network)
            source_network_created = True
            docker("network", "create", source_network)
            require(json.loads(docker("network", "inspect", network))[0]["Internal"], "application network is not internal")
            volume_created = True
            docker("volume", "create", volume)
            def security_options(pod_spec, container):
                security = {**pod_spec.get("securityContext", {}), **container.get("securityContext", {})}
                options = []
                if "runAsUser" in security:
                    options += ["--user", str(security["runAsUser"]) + (":" + str(security["runAsGroup"]) if "runAsGroup" in security else "")]
                for group in security.get("supplementalGroups", []):
                    options += ["--group-add", str(group)]
                if security.get("allowPrivilegeEscalation") is False:
                    options += ["--security-opt", "no-new-privileges=true"]
                for action in ("drop", "add"):
                    for capability in security.get("capabilities", {}).get(action, []):
                        options += ["--cap-" + action, capability]
                if security.get("readOnlyRootFilesystem"):
                    options += ["--read-only"]
                return options


            def mount(subpath, target, readonly=False):
                # Kubernetes volumes do not copy image-directory contents or ownership.
                return ("--mount", f"type=volume,src={volume},dst={target},volume-subpath={subpath},volume-nocopy" + (",readonly" if readonly else ""))

            def run(name, image, *options, argv=(), environment=None, detached=False, failure=False, timeout=900):
                container = network + "-" + name
                owned_containers.append(container)  # Register before run: timeouts must not orphan containers.
                parameters = [*docker_prefix, "run", "--name", container, "--platform", args.platform, "--network", network]
                # Detached helpers remain inspectable until their real exit
                # status is collected; all containers use owned cleanup below.
                if not detached:
                    parameters.append("--rm")
                if detached:
                    parameters.append("-d")
                parameters.extend(options)
                env = {**docker_env, **(environment or {})}
                for key in environment or {}:
                    parameters += ["-e", key]
                result = subprocess.run([*parameters, image, *argv], capture_output=True, text=True, timeout=timeout, env=env)
                require_container_exit(result, failure, name)
                return container

            # The setup helper owns only this new Linux volume; application
            # daemons retain production entrypoints, IDs and supplemental groups.
            keeper = run("fixture", apps["sabnzbd"]["image"], "-v", volume + ":/fixture", "--entrypoint", "/lsiopy/bin/python", argv=("-c", "import time; time.sleep(86400)"), detached=True)
            request = partial(request_from_container, docker, keeper)
            page = partial(page_from_container, docker, keeper)

            def gateway_headers(app):
                # The HTTP shape of a request the Gateway forwards after Kanidm
                # sign-in: the route's public Host and an outside client in
                # X-Forwarded-For. Caller admission is proved separately by
                # media-ingress-runtime, not by this Docker network.
                return {"Host": gateway_hosts[app], "X-Forwarded-For": "203.0.113.7", "X-Forwarded-Proto": "https"}
            setup = {
                "identities": identities, "media_gid": media_gid,
                "directories": [policy["arr"][app]["standard"]["root"].removeprefix("/data/") for app in ("radarr", "sonarr")]
            }
            docker("exec", keeper, "/lsiopy/bin/python", "-c", '''import json, os, sys
from pathlib import Path
s = json.loads(sys.argv[1]); root = Path('/fixture')
for app, (uid, gid, groups) in s['identities'].items():
    p = root / app; p.mkdir(); os.chown(p, uid, gid); p.chmod(0o750 if app == 'jellyfin' else 0o700)
data = root / 'data'; data.mkdir(); os.chown(data, 0, s['media_gid']); data.chmod(0o2770)
for name in s['directories'] + ['library/movies-ui', 'downloads/usenet/incomplete', 'downloads/usenet/complete']:
    path = data / name; path.mkdir(parents=True, exist_ok=True)
    for p in [path, *path.parents]:
        if p == root: break
        os.chown(p, 0, s['media_gid']); p.chmod(0o2770)
private = data / 'private'; private.mkdir(); os.chown(private, 0, 999); private.chmod(0o700)
for name in ['config', 'seerr-inputs', 'secrets', 'kube']:
    p = root / name; p.mkdir(); os.chown(p, 1000, 1000); p.chmod(0o755)
coordination = root / 'coordination'; coordination.mkdir(); os.chown(coordination, 1000, 1000); coordination.chmod(0o700)
for name in ['seerr-drift-inputs', 'seerr-failure-secrets']:
    p = root / name; p.mkdir(); os.chown(p, 1000, 1000); p.chmod(0o755)
''', json.dumps(setup))

            def copy_text(subpath, content):
                source = root / "payload"
                source.write_text(content)
                source.chmod(0o644)
                docker("cp", str(source), keeper + ":/fixture/" + subpath)

            copy_text("config/config.yml", cm["config.yml"])
            copy_text("config/invalid.yml", "radarr: [broken\n")
            copy_text("config/previous-pin.yml", cm["config.yml"].replace(
                policy_source["templateRevision"], previous_template_revision))
            ports, containers = {}, {}

            def start(app, port, restart=False):
                hostname = policy["jellyfin"]["ip"] if app == "jellyfin" else app + ".media.svc"
                options = [*mount(app, "/app/config" if app == "seerr" else "/config"), "--network-alias", hostname]
                if app in ("radarr", "sonarr", "sabnzbd"):
                    options += mount("data", "/data")
                if app == "jellyfin":
                    options += mount("data/library", "/media", True)
                    options += ["--tmpfs", "/cache:mode=0777,size=4g"]
                for hook in apps[app].get("volumeMounts", []):
                    if not hook["mountPath"].startswith("/custom-cont-init.d/"):
                        continue
                    source = one(pods[app]["volumes"], "name", hook["name"])["configMap"]
                    content = manifest(app, "ConfigMap-" + source["name"] + ".yaml")["data"][hook["subPath"]]
                    subpath = "hooks/" + app + "/" + hook["subPath"]
                    docker("exec", keeper, "/lsiopy/bin/python", "-c",
                           "from pathlib import Path; import sys; Path('/fixture', sys.argv[1]).parent.mkdir(parents=True, exist_ok=True)", subpath)
                    copy_text(subpath, content)
                    docker("exec", keeper, "/lsiopy/bin/python", "-c",
                           "import os, sys; p='/fixture/'+sys.argv[1]; os.chown(p,0,0); os.chmod(p,int(sys.argv[2]))",
                           subpath, str(source.get("defaultMode", 420)))
                    options += mount(subpath, hook["mountPath"], hook.get("readOnly", False))
                options += security_options(pods[app], apps[app])
                environment = {item["name"]: item.get("value", runtime.get(item.get("valueFrom", {}).get("secretKeyRef", {}).get("key"))) for item in apps[app].get("env", [])}
                require(all(value is not None for value in environment.values()), "unresolved synthetic container environment")
                containers[app] = run(app + ("-rotated" if restart else ""), apps[app]["image"], *options, environment=environment, detached=True)
                ports[app] = f"{hostname}:{port}"

            def api(app, path, method="GET", body=None, key=None):
                return request(ports[app], f"/api/v{1 if app == 'prowlarr' else 3}" + path, key=keys[app] if key is None else key, method=method, body=body)

            for app, port in (("radarr", 7878), ("sonarr", 8989), ("prowlarr", 9696)):
                start(app, port)
                ready(request, ports[app], f"/api/v{1 if app == 'prowlarr' else 3}/system/status", key=keys[app])
                denied(lambda app=app: api(app, "/system/status", key=keys["sonarr" if app != "sonarr" else "radarr"]))
                # Browser sign-in is the Gateway's alone. A request shaped like
                # one the Gateway forwards gets the app shell, not /login, and
                # the browser receives the API key; the API itself still
                # refuses a request without a key.
                version = 1 if app == "prowlarr" else 3
                require(api(app, "/system/status")["authentication"] == "external", f"{app} does not use External authentication")
                shell = page(ports[app], "/", gateway_headers(app))
                require(shell["status"] == 200 and not shell["location"] and b"<html" in shell["body"].lower(),
                        f"{app} web UI asked for its own login (HTTP {shell['status']} -> {shell['location']})")
                initialize = page(ports[app], "/initialize.json", gateway_headers(app))
                require(initialize["status"] == 200 and json.loads(initialize["body"])["apiKey"] == keys[app],
                        f"{app} web UI did not start without a login")
                require(page(ports[app], f"/api/v{version}/system/status", gateway_headers(app))["status"] == 401,
                        f"{app} API answered without a key")
            unmanaged_application = api("prowlarr", "/applications", "POST", {
                "name": "UI-owned Radarr", "implementation": "Radarr", "configContract": "RadarrSettings", "syncLevel": "addOnly", "tags": [],
                "fields": [{"name": "prowlarrUrl", "value": "http://prowlarr.media.svc:9696"}, {"name": "baseUrl", "value": policy["arr"]["radarr"]["standard"]["url"]}, {"name": "apiKey", "value": keys["radarr"]}],
            })
            unmanaged_profiles, unmanaged_formats = {}, {}
            for app in ("radarr", "sonarr"):
                call = lambda path, method="GET", body=None, app=app: api(app, path, method, body)
                # Native root admission probes daemon access to the real Linux volume.
                denied(lambda: call("/rootfolder", "POST", {"path": "/data/private"}), statuses=(400,))
                try:
                    call("/rootfolder", "POST", {"path": policy["arr"][app]["standard"]["root"]})
                except HTTPError as error:
                    daemon_identity(docker, containers[app], "Radarr" if app == "radarr" else "Sonarr", identities[app])
                    raise AssertionError(f"{app} daemon cannot admit declared Linux media root: HTTP {error.code}") from None
                daemon_identity(docker, containers[app], "Radarr" if app == "radarr" else "Sonarr", identities[app])
                ui_profile = deepcopy(call("/qualityprofile")[0]); ui_profile.pop("id"); ui_profile["name"] = "UI-owned profile"
                unmanaged_profiles[app] = call("/qualityprofile", "POST", ui_profile)
                unmanaged_formats[app] = call("/customformat", "POST", {
                    "name": "UI-owned custom format", "includeCustomFormatWhenRenaming": False,
                    "specifications": [{
                        "name": "UI-owned match", "implementation": "ReleaseTitleSpecification",
                        "negate": False, "required": False,
                        "fields": [{"name": "value", "value": "NEVERMATCHUI"}],
                    }],
                })
            api("radarr", "/rootfolder", "POST", {"path": "/data/library/movies-ui"})

            def initialize_sab(name):
                init = pods["sabnzbd"]["initContainers"][0]
                run(name, apps["sabnzbd"]["image"], *security_options(pods["sabnzbd"], init), *mount("sabnzbd", "/config"), *mount("data", "/data"), "--entrypoint", init["command"][0], argv=tuple(init["command"][1:]), environment=runtime)

            initialize_sab("sab-init")
            start("sabnzbd", 8080)
            sab_query = "/api?" + urlencode({"mode": "get_config", "output": "json", "apikey": runtime["SABNZBD_API_KEY"]})
            ready(request, ports["sabnzbd"], "/api?" + urlencode({"mode": "version", "output": "json", "apikey": runtime["SABNZBD_API_KEY"]}))
            daemon_identity(docker, containers["sabnzbd"], "SABnzbd.py", identities["sabnzbd"])
            sab_config = request(ports["sabnzbd"], sab_query)["config"]
            require(sab_config["misc"]["download_dir"] == "/data/downloads/usenet/incomplete" and sab_config["misc"]["complete_dir"] == "/data/downloads/usenet/complete", "SAB native data paths differ")
            for app in ("radarr", "sonarr"):
                category = policy["arr"][app]["standard"]["category"]
                actual_dir = one(sab_config["categories"], "name", category)["dir"]
                require(actual_dir == category, f"SAB category {category!r}: native directory {actual_dir!r}, expected {category!r}")
                # Exercise SAB's real directory/post-processing code as its daemon user.
                downloaded = docker("exec", containers["sabnzbd"], "/command/s6-setuidgid", "abc", "/lsiopy/bin/python", "-c", '''
import os, sys
from pathlib import Path
sys.path.insert(0, '/app/sabnzbd')
import sabnzbd.cfg
from sabnzbd.filesystem import create_all_dirs, set_permissions
sabnzbd.cfg.permissions.set(sys.argv[1])
release = Path(sys.argv[2]) / sys.argv[3] / 'shared-permission-fixture'
assert create_all_dirs(str(release), apply_permissions=True)
video = release / 'fixture.mkv'
video.write_bytes(b'shared download payload')
set_permissions(str(release))
assert release.stat().st_gid == video.stat().st_gid == int(sys.argv[4]), 'download lost the shared media group'
assert release.stat().st_mode & 0o2000, 'download directory lost setgid'
assert video.stat().st_mode & 0o7117 == 0, 'download permits world access or execution'
print(video)
''', str(sab_config["misc"]["permissions"]), sab_config["misc"]["complete_dir"], category, str(media_gid))
                require(docker("exec", containers[app], "/command/s6-setuidgid", "abc", "/bin/cat", downloaded) == "shared download payload",
                        f"{app} cannot read SAB's completed download")
            denied(lambda: request(ports["sabnzbd"], "/api?" + urlencode({"mode": "get_config", "output": "json", "apikey": keys["radarr"]})), statuses=(403,))
            # SABnzbd's web login is off; the Gateway's Kanidm sign-in is the only one.
            require(sab_config["misc"]["username"] == "" and sab_config["misc"]["password"] == "", "SAB still has a web login")
            require(int(sab_config["misc"]["inet_exposure"]) == 4, "SAB does not give Gateway clients its full web interface")
            sab_home = page(ports["sabnzbd"], "/", gateway_headers("sabnzbd"))
            require("/login" not in (sab_home["location"] or ""), f"SAB web UI asked for its own login (HTTP {sab_home['status']})")
            for headers in (gateway_headers("sabnzbd"), {}):
                # Through the Gateway's Host and the internal Service name alike.
                sab_main = page(ports["sabnzbd"], "/?skip_wizard=1", headers)
                require(sab_main["status"] == 200 and b"<html" in sab_main["body"].lower(), f"SAB web UI did not open without a login (HTTP {sab_main['status']})")
            require(page(ports["sabnzbd"], "/?skip_wizard=1", {"Host": "rebind.example.test"})["status"] == 403, "SAB accepted an unlisted Host without a login")
            require(page(ports["sabnzbd"], "/api?" + urlencode({"mode": "queue", "output": "json"}), gateway_headers("sabnzbd"))["status"] == 403, "SAB API answered without a key")

            def lock_held(name="seerr"):
                return docker("exec", keeper, "/lsiopy/bin/python", "-c", '''import fcntl, sys
with open('/fixture/coordination/' + sys.argv[1] + '.lock', 'r') as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('held')
    else:
        print('free')
''', name) == "held"
            # /proc/locks filters PID namespaces. This read-only fixture observer
            # uses daemon-host PIDs; neither producer entry point is changed.
            lock_observer = run(
                "lock-observer", configure["image"], "--pid", "host",
                "--user", "1000:1000", "--cap-drop", "ALL",
                "--security-opt", "no-new-privileges=true", "--read-only",
                *mount("coordination", "/coordination", True),
                argv=("node", "-e", "setInterval(() => {}, 1000)"), detached=True,
            )
            sequence = 0
            def reconcile_configarr(failure=False, overrides=None, periodic=False, detached=False, fetch=True):
                nonlocal sequence
                sequence += 1
                source_pod = periodic_configarr_pod if periodic else configarr_pod
                source = periodic_configarr if periodic else configarr
                environment = {item["name"]: item.get("value", runtime.get(item.get("valueFrom", {}).get("secretKeyRef", {}).get("key"))) for item in source["env"]}
                environment.update(overrides or {})
                return run("configarr-" + str(sequence), source["image"], *security_options(source_pod, source),
                           *mount("config", "/app/config", True), *mount("coordination", "/coordination"),
                           *(("--network", source_network) if fetch else ()),
                           "--entrypoint", source["command"][0], argv=tuple(source["command"][1:]),
                           environment=environment, failure=failure, detached=detached)

            def verify_arr(app):
                desired = policy["arr"][app]["standard"]
                call = lambda path: api(app, path)
                require([item["path"] for item in call("/rootfolder")] == [desired["root"]], "native managed root folders differ")
                require({item["name"] for item in call("/customformat")} ==
                        {item["name"] for item in expected_formats[app].values()} | {"UI-owned custom format"},
                        "native CF groups added or removed an unapproved format")
                for profile in expected_profiles[app].values():
                    verify_profile(call, profile, expected_formats[app])
                verify_hd_menu(call, app)
                verify_format_policy(call, app, expected_profiles[app])
                unmanaged = call("/qualityprofile/" + str(unmanaged_profiles[app]["id"]))
                require({key: value for key, value in unmanaged.items() if key != "formatItems"} == {key: value for key, value in unmanaged_profiles[app].items() if key != "formatItems"}, "unmanaged quality profile changed")
                old_scores = {item["format"]: item["score"] for item in unmanaged_profiles[app]["formatItems"]}
                actual_scores = {item["format"]: item["score"] for item in unmanaged["formatItems"]}
                require(all(actual_scores.get(key) == value for key, value in old_scores.items()), "unmanaged profile scores changed")
                require(call("/customformat/" + str(unmanaged_formats[app]["id"])) == unmanaged_formats[app], "unmanaged custom format changed")
                client = one(call("/downloadclient"), "name", "SABnzbd (Homelab)")
                require(client["implementation"] == "Sabnzbd" and client["enable"] is True, "native SAB client not enabled")
                values = fields(client)
                expected = {"host": policy["sab"]["host"], "port": policy["sab"]["port"], "useSsl": False, "urlBase": "", "username": "", "movieCategory" if app == "radarr" else "tvCategory": desired["category"]}
                require(all(values.get(name) == value for name, value in expected.items()), "native SAB mapping differs in fields: " + ", ".join(name for name, value in expected.items() if values.get(name) != value))
                # Native provider APIs redact credentials. Prove their use by
                # the real handshake and denial with another instance's key.
                api(app, "/downloadclient/test", "POST", client)
                wrong_client = deepcopy(client)
                next(item for item in wrong_client["fields"] if item["name"] == "apiKey")["value"] = keys["prowlarr"]
                denied(lambda: api(app, "/downloadclient/test", "POST", wrong_client), statuses=(400,))
                require(not any("search" in item["name"].lower() or "upgrade" in item["name"].lower() for item in call("/command")), "reconciliation launched search/upgrade commands")
                verify_preserved()

            def verify_prowlarr():
                current = api("prowlarr", "/applications")
                require(one(current, "name", "UI-owned Radarr") == unmanaged_application, "unmanaged Prowlarr application changed")
                for app in ("radarr", "sonarr"):
                    desired = policy["arr"][app]["standard"]
                    application = one(current, "name", "homelab-" + desired["name"])
                    require(application["implementation"].lower() == app and application["syncLevel"] == "fullSync", "Prowlarr native application/sync mapping differs")
                    values = fields(application)
                    require(values["baseUrl"] == desired["url"] and values["prowlarrUrl"] == "http://prowlarr.media.svc:9696", "Prowlarr native endpoint mapping differs")
                    api("prowlarr", "/applications/test", "POST", application)
                    wrong_application = deepcopy(application)
                    next(item for item in wrong_application["fields"] if item["name"] == "apiKey")["value"] = runtime["SABNZBD_API_KEY"]
                    denied(lambda: api("prowlarr", "/applications/test", "POST", wrong_application), statuses=(400,))

            def arr_snapshot():
                snapshot = {app: {path: [{key: value for key, value in item.items() if key != "freeSpace"} for item in api(app, path)] for path in ("/rootfolder", "/qualityprofile", "/customformat", "/downloadclient")} for app in ("radarr", "sonarr")}
                # Score updates can reorder formatItems; format IDs and scores,
                # not this presentation order, are the preservation boundary.
                for resources in snapshot.values():
                    for profile in resources["/qualityprofile"]:
                        profile["formatItems"].sort(key=lambda item: item["format"])
                return snapshot

            start("jellyfin", policy["jellyfin"]["port"])
            ready(request, ports["jellyfin"], "/Users/Public")
            def jellyfin(path, method="GET", body=None, key=None, binary=False):
                return request(ports["jellyfin"], path, key=key, method=method, body=body, jellyfin=True, binary=binary)
            owner_password = secrets.token_hex(32)
            require(jellyfin("/System/Info/Public")["StartupWizardCompleted"] is False, "fixture Jellyfin unexpectedly claimed")
            jellyfin("/Startup/Configuration", "POST", {"UICulture": "en-US", "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en"})
            jellyfin("/Startup/User")  # Native wizard initializes the first user here.
            jellyfin("/Startup/User", "POST", {"Name": policy["jellyfin"]["username"], "Password": owner_password})
            jellyfin("/Startup/Complete", "POST", {})
            owner_token = jellyfin("/Users/AuthenticateByName", "POST", {"Username": policy["jellyfin"]["username"], "Pw": owner_password})["AccessToken"]
            denied(lambda: jellyfin("/Library/VirtualFolders", key=keys["radarr"]))
            daemon_identity(docker, containers["jellyfin"], "/jellyfin/jellyfin", identities["jellyfin"])

            def add_library(library):
                jellyfin("/Library/VirtualFolders?" + urlencode({"name": library["name"], "collectionType": library["collectionType"], "refreshLibrary": "false"}), "POST", {"LibraryOptions": {"PathInfos": [{"Path": item["path"]} for item in library["libraryOptions"]["pathInfos"]]}}, key=owner_token)
            for library in libraries[:-1]:
                add_library(library)
            # This native item is unmanaged by Arr and survives root-record deletion.
            # Jellyfin's own ffmpeg makes a legal local-only video, not a host echo.
            run("legal-video", apps["jellyfin"]["image"], *mount("data", "/data"), "--entrypoint", "/usr/lib/jellyfin-ffmpeg/ffmpeg", argv=("-nostdin", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=1", "-c:v", "mpeg4", "/data/library/movies-ui/Fixture.mp4"))
            docker("exec", keeper, "/lsiopy/bin/python", "-c", "import os; p='/fixture/data/library/movies-ui/Fixture.mp4'; os.chown(p,0,int(__import__('sys').argv[1])); os.chmod(p,0o660)", str(media_gid))
            # Seerr scans each library in 20-item batches. A finished scan
            # reports the last batch's start index as progress and the last
            # library's item count as total. More than one Movies batch before
            # the empty Shows library makes progress exceed total.
            movie_batch = 21
            docker("exec", keeper, "/lsiopy/bin/python", "-c", '''import os, shutil, sys
for index in range(int(sys.argv[2])):
    p = '/fixture/data/library/movies/Scan Fixture %02d.mp4' % index
    shutil.copyfile('/fixture/data/library/movies-ui/Fixture.mp4', p); os.chown(p, 0, int(sys.argv[1])); os.chmod(p, 0o660)''', str(media_gid), str(movie_batch))
            unmanaged_library = {"name": "UI-owned library", "collectionType": "movies", "libraryOptions": {"pathInfos": [{"path": "/media/movies-ui"}]}}
            add_library(unmanaged_library)
            jellyfin("/Library/Refresh", "POST", key=owner_token)
            deadline = time.monotonic() + 180
            preserved_item = None
            while time.monotonic() < deadline:
                items = jellyfin("/Items?Recursive=true&Fields=Path&IncludeItemTypes=Movie", key=owner_token)["Items"]
                matches = [item for item in items if item.get("Path") == "/media/movies-ui/Fixture.mp4"]
                movies = [item for item in items if item.get("Path", "").startswith("/media/movies/")]
                if len(matches) == 1 and len(movies) == movie_batch:
                    preserved_item = matches[0]["Id"]; break
                time.sleep(2)
            require(preserved_item is not None, "Jellyfin daemon could not read unmanaged legal media and the Movies batch")
            stream_path = "/Videos/" + preserved_item + "/stream.mp4?Static=true"
            preserved_digest = hashlib.sha256(jellyfin(stream_path, key=owner_token, binary=True)).digest()
            def verify_preserved():
                require(hashlib.sha256(jellyfin(stream_path, key=owner_token, binary=True)).digest() == preserved_digest, "Jellyfin daemon cannot serve preserved unmanaged media")

            reconcile_configarr(failure=True, overrides={"CONFIG_LOCATION": "/app/config/invalid.yml"})
            # Read native Git state and upstream inputs, not the policy Configarr
            # happened to persist in Arr. Both repositories must be the pinned SHAs.
            def cache_state(repository_root=cache_root):
                return json.loads(docker("exec", keeper, "/lsiopy/bin/python", "-c", '''
import json, sys
from pathlib import Path
root = Path('/fixture' + sys.argv[1])
print(json.dumps({name: {'head': (root / name / '.git/HEAD').read_text().strip()}
                  for name in ['trash-guides', 'recyclarr-config']}))
''', repository_root))
            # A genuine shallow A-only upstream cache must lack B, even though
            # a full clone made today would already contain both commits.
            run("previous-policy-cache", configarr["image"], *security_options(configarr_pod, configarr),
                *mount("coordination", "/coordination"), "--network", source_network,
                "--entrypoint", "/bin/sh", argv=("-ec", '''
set -eu
repo="$1/recyclarr-config"
git init -q "$repo"
git -C "$repo" remote add origin "$2"
git -C "$repo" fetch --quiet --depth=1 origin "$3"
git -C "$repo" checkout --quiet --detach FETCH_HEAD
test "$(git -C "$repo" rev-parse HEAD)" = "$3"
test "$(git -C "$repo" rev-parse --is-shallow-repository)" = true
test "$(printf '%s\\n' "$4" | GIT_NO_LAZY_FETCH=1 git -C "$repo" cat-file --batch-check)" = "$4 missing"
''', "previous-policy-cache", previous_cache_root, policy_source["templateRepository"],
                previous_template_revision, policy_source["templateRevision"]))
            # Populate a real older pin pair first. Switching to the production
            # pair must succeed natively without deleting or rewriting that cache.
            reconcile_configarr(overrides={
                "CONFIG_LOCATION": "/app/config/previous-pin.yml",
                "CUSTOM_REPO_ROOT": previous_cache_root,
            })
            previous_cache = cache_state(previous_cache_root)
            require(previous_cache["trash-guides"]["head"] == policy_source["revision"], "previous native guide pin differs")
            require(previous_cache["recyclarr-config"]["head"] == previous_template_revision, "previous native template pin differs")
            run("previous-pin-missing", configarr["image"], *security_options(configarr_pod, configarr),
                *mount("coordination", "/coordination", True), "--entrypoint", "/bin/sh",
                argv=("-ec", '''
set -eu
repo="$1/recyclarr-config"
test "$(git -C "$repo" rev-parse --is-shallow-repository)" = true
test "$(printf '%s\\n' "$2" | GIT_NO_LAZY_FETCH=1 git -C "$repo" cat-file --batch-check)" = "$2 missing"
''', "previous-pin-missing", previous_cache_root, policy_source["templateRevision"]))
            previous_policy = arr_snapshot()
            reconcile_configarr()
            require(cache_state(previous_cache_root) == previous_cache, "pin change altered the older native cache")
            require(arr_snapshot() == previous_policy, "native pin change altered application identities or data")
            cold_cache = cache_state()
            require(cold_cache["trash-guides"]["head"] == policy_source["revision"], "native TRaSH checkout is not pinned")
            require(cold_cache["recyclarr-config"]["head"] == policy_source["templateRevision"], "native template checkout is not pinned")
            upstream = json.loads(docker("exec", keeper, "/lsiopy/bin/python", "-c", '''
import json, sys
from pathlib import Path
source, required = json.loads(sys.argv[1]), json.loads(sys.argv[2])
root = Path('/fixture' + sys.argv[3]) / 'trash-guides/docs/json'
result = {}
for app in ['radarr', 'sonarr']:
    profiles = {value['trash_id']: value for path in (root / app / 'quality-profiles').glob('*.json')
                for value in [json.loads(path.read_text())]
                if value['trash_id'] in {item['id'] for item in source['profiles'][app].values()}}
    ids = set(required[app]['default'] + required[app]['zero'])
    ids.update(trash_id for profile in profiles.values() for trash_id in profile['formatItems'].values())
    formats = {value['trash_id']: value for path in (root / app / 'cf').glob('*.json')
               for value in [json.loads(path.read_text())] if value['trash_id'] in ids}
    assert set(formats) == ids
    result[app] = {'profiles': profiles, 'formats': formats}
print(json.dumps(result))
''', json.dumps(policy_source), json.dumps(required_formats), cache_root))
            expected_formats = {app: values["formats"] for app, values in upstream.items()}
            expected_profiles = {
                app: profile_expectations(cm["config.yml"], upstream[app]["profiles"], expected_formats[app],
                                          api(app, "/qualitydefinition"), app, policy["arr"][app]["standard"]["name"])
                for app in ("radarr", "sonarr")
            }
            for app in ("radarr", "sonarr"):
                verify_arr(app)
            verify_prowlarr()
            # A UI-owned profile may score a managed/shared format differently.
            # Reconciliation must preserve that deliberate user assignment.
            for app in ("radarr", "sonarr"):
                shared_ids = [one(api(app, "/customformat"), "name", name)["id"] for name in ("WEB Tier 01", "AMZN")]
                profile = api(app, "/qualityprofile/" + str(unmanaged_profiles[app]["id"]))
                for shared_id in shared_ids:
                    one(profile["formatItems"], "format", shared_id)["score"] = 73
                api(app, "/qualityprofile/" + str(profile["id"]), "PUT", profile)
                unmanaged_profiles[app] = api(app, "/qualityprofile/" + str(profile["id"]))
                require(all(one(unmanaged_profiles[app]["formatItems"], "format", shared_id)["score"] == 73
                            for shared_id in shared_ids),
                        "native UI-owned profile did not retain its independent shared-format scores")
            baseline = arr_snapshot()
            prowlarr_ids = {item["name"]: item["id"] for item in api("prowlarr", "/applications")}
            # A different ordinary Job reuses the same cache with no source-network
            # attachment: a warm detached pin must not need another repository clone.
            reconcile_configarr(periodic=True, fetch=False)
            require(cache_state() == cold_cache, "warm internal-only Job changed pinned repository revisions")
            require(arr_snapshot() == baseline, "second reconcile changed native Arr identities/state")
            verify_prowlarr()
            require({item["name"]: item["id"] for item in api("prowlarr", "/applications")} == prowlarr_ids, "second reconcile changed Prowlarr identities")

            # Exercise both producer entry points, including release after a
            # failed API write. Observe genuine score drift while the contender
            # is queued on the same kernel inode, then prove reconciliation.
            for failed_holder in (False, True):
                for app in ("radarr", "sonarr", "prowlarr"):
                    docker("pause", containers[app])
                holder = reconcile_configarr(periodic=failed_holder, detached=True,
                                             overrides={"SONARR_API_KEY": keys["radarr"]} if failed_holder else None)
                deadline = time.monotonic() + 10
                while not lock_held("configarr"):
                    require(time.monotonic() < deadline, "Configarr producer did not acquire its shared lock")
                    time.sleep(0.05)
                docker("pause", holder)
                for app in ("radarr", "sonarr", "prowlarr"):
                    docker("unpause", containers[app])
                desired_profile = expected_profiles["radarr"][policy["arr"]["radarr"]["standard"]["profile"]]
                profile = one(api("radarr", "/qualityprofile"), "name", desired_profile["name"])
                wrong = deepcopy(profile)
                owned_id = verify_profile(lambda path: api("radarr", path), desired_profile, expected_formats["radarr"])[1][next(iter(desired_profile["formatScores"]))]
                one(wrong["formatItems"], "format", owned_id)["score"] += 1
                api("radarr", "/qualityprofile/" + str(profile["id"]), "PUT", wrong)
                waiter = reconcile_configarr(periodic=not failed_holder, detached=True)
                waiter_pid = docker("inspect", "--format", "{{.State.Pid}}", waiter)
                require(waiter_pid.isdigit() and int(waiter_pid) > 0, "Configarr contender has no daemon-host PID")
                deadline = time.monotonic() + 10
                while True:
                    waiting = docker("exec", lock_observer, "node", "-e", '''const fs = require('node:fs');
const pid = process.argv[1];
const inode = String(fs.statSync('/coordination/configarr.lock', {bigint: true}).ino);
const queued = fs.readFileSync('/proc/locks', 'utf8').split('\\n').some(line => {
  const row = line.trim().split(/\\s+/);
  if (row[1] !== '->' || row[2] !== 'FLOCK' || row[6].split(':').at(-1) !== inode) return false;
  return fs.readFileSync('/proc/' + row[5] + '/status', 'utf8').match(/^PPid:\\s+(\\d+)$/m)?.[1] === pid;
});
console.log(queued);''', waiter_pid)
                    if waiting == "true":
                        break
                    require(time.monotonic() < deadline, "Configarr contender did not block on the shared inode")
                    time.sleep(0.05)
                for _ in range(3):
                    actual_score = one(api("radarr", "/qualityprofile/" + str(profile["id"]))["formatItems"], "format", owned_id)["score"]
                    require(actual_score == one(wrong["formatItems"], "format", owned_id)["score"],
                            "waiting Configarr entry point changed native policy while lock held")
                    require(lock_held("configarr"), "paused Configarr producer lost its lock")
                    time.sleep(0.1)
                docker("unpause", holder)
                for helper, failure in ((holder, failed_holder), (waiter, False)):
                    status = int(docker("wait", helper, timeout=900))
                    require_application_exit(status, failure, "serialized Configarr producer")
                require(not lock_held("configarr"), "Configarr producer exit retained its lock")
                for app in ("radarr", "sonarr"):
                    verify_arr(app)
                verify_prowlarr()
                require(arr_snapshot() == baseline, "serialized Configarr repair changed native identities/unmanaged state")
            reconcile_configarr(failure=True, overrides={"SONARR_API_KEY": keys["radarr"]})
            require(arr_snapshot() == baseline, "wrong native credential changed Arr state")
            # Drift each selected profile in turn, including formats shared by
            # all profiles. Repair must not copy scores between profiles or
            # replace any sibling/UI-owned record.
            for app in ("radarr", "sonarr"):
                owned_id = one(api(app, "/customformat"), "name", "WEB Tier 01")["id"]
                for desired_profile in expected_profiles[app].values():
                    profile = one(api(app, "/qualityprofile"), "name", desired_profile["name"])
                    wrong = deepcopy(profile)
                    one(wrong["formatItems"], "format", owned_id)["score"] += 1
                    quality = ("Bluray-720p" if desired_profile["name"] == "HD Preferred" else
                               "Bluray-2160p" if desired_profile["name"].startswith("Remux") else "Bluray-1080p")
                    item = next(item for item in wrong["items"] if item.get("quality", {}).get("name") == quality)
                    original_allowed = item["allowed"]
                    quality_id = item["quality"]["id"]
                    item["allowed"] = not original_allowed
                    api(app, "/qualityprofile/" + str(profile["id"]), "PUT", wrong)
                    rejected(lambda: verify_format_policy(lambda path: api(app, path), app, expected_profiles[app]),
                             "wrong native custom format score")
                    rejected(lambda: verify_hd_menu(lambda path: api(app, path), app), "wrong native quality gate")
                    # Clean up only the quality probe; Configarr must still
                    # repair the independent score drift below.
                    current = api(app, "/qualityprofile/" + str(profile["id"]))
                    next(item for item in current["items"] if item.get("quality", {}).get("id") == quality_id)["allowed"] = original_allowed
                    api(app, "/qualityprofile/" + str(profile["id"]), "PUT", current)
                    verify_hd_menu(lambda path: api(app, path), app)
                    rejected(lambda: verify_format_policy(lambda path: api(app, path), app, expected_profiles[app]),
                             "quality probe cleanup restored native score drift")
                    for sibling in expected_profiles[app].values():
                        if sibling["name"] != desired_profile["name"]:
                            verify_profile(lambda path: api(app, path), sibling, expected_formats[app])
                    reconcile_configarr()
                    verify_arr(app)
                    require(arr_snapshot() == baseline, "per-profile score repair replaced native identities or sibling/unmanaged state")
            # Radarr's required AMZN marker has an explicit guide score zero,
            # not an upstream default. Sonarr's same-named marker scores 75.
            # Drift every native profile, then repair them in one ordinary run.
            for app in ("radarr", "sonarr"):
                format_id = one(api(app, "/customformat"), "name", "AMZN")["id"]
                for name in expected_profiles[app]:
                    profile = one(api(app, "/qualityprofile"), "name", name)
                    one(profile["formatItems"], "format", format_id)["score"] = 49
                    api(app, "/qualityprofile/" + str(profile["id"]), "PUT", profile)
                    rejected(lambda: verify_format_policy(lambda path: api(app, path), app, [name]),
                             "wrong native AMZN zero/default score")
            reconcile_configarr()
            for app in ("radarr", "sonarr"):
                verify_arr(app)
            require(arr_snapshot() == baseline, "AMZN score repair lost native identities or UI-owned scores")
            root_record = api("sonarr", "/rootfolder")[0]
            api("sonarr", "/rootfolder/" + str(root_record["id"]), "DELETE")
            rejected(lambda: verify_arr("sonarr"), "missing native root folder")
            reconcile_configarr()
            verify_arr("sonarr")
            rotated_baseline = arr_snapshot()
            docker("rm", "-f", "-v", containers["sabnzbd"])
            runtime["SABNZBD_API_KEY"] = secrets.token_hex(32)
            reconcile_configarr(failure=True)
            require(arr_snapshot() == rotated_baseline, "failed SAB handshake changed visible Arr configuration")
            initialize_sab("sab-init-rotated")
            start("sabnzbd", 8080, restart=True)
            ready(request, ports["sabnzbd"], "/api?" + urlencode({"mode": "version", "output": "json", "apikey": runtime["SABNZBD_API_KEY"]}))
            reconcile_configarr()
            for app in ("radarr", "sonarr"):
                verify_arr(app)
                require(one(api(app, "/downloadclient"), "name", "SABnzbd (Homelab)")["id"] == one(baseline[app]["/downloadclient"], "name", "SABnzbd (Homelab)")["id"], "credential rotation replaced native client identity")

            def verify_libraries():
                folders = jellyfin("/Library/VirtualFolders", key=owner_token)
                for desired in [*libraries, unmanaged_library]:
                    actual = one(folders, "Name", desired["name"])
                    require(actual["CollectionType"] == desired["collectionType"] and sorted(actual["Locations"]) == sorted(item["path"] for item in desired["libraryOptions"]["pathInfos"]), "native Jellyfin library type/path differs")
                item = jellyfin("/Items/" + preserved_item, key=owner_token)
                require(item["Id"] == preserved_item and item["Path"] == "/media/movies-ui/Fixture.mp4", "unmanaged media was lost or replaced")
                verify_preserved()
                return {item["Name"]: item["ItemId"] for item in folders}

            # Seerr refreshes this mapping before any library scan and aborts
            # the scan when the download fails, as it does on this internal
            # network. A fresh copy stands in for a successful download, so the
            # full sync really scans the declared libraries.
            copy_text("seerr/anime-list.xml", '<anime-list><anime anidbid="1"/></anime-list>\n')
            start("seerr", 5055)
            public = ready(request, ports["seerr"], "/api/v1/settings/public")
            require(public["mediaServerType"] == 4 and public["initialized"] is False, "fixture Seerr unexpectedly claimed")
            seerr_api = lambda path, key=None: request(ports["seerr"], "/api/v1" + path, key=keys["seerr"] if key is None else key)
            denied(lambda: seerr_api("/auth/me", key=keys["radarr"]))
            copy_text("seerr-inputs/seerr.json", cm["seerr.json"])
            copy_text("seerr-inputs/seerr.mjs", cm["seerr.mjs"])
            for name in ("SEERR_API_KEY", "RADARR_API_KEY", "SONARR_API_KEY"):
                copy_text("secrets/" + name, runtime[name] + "\n")
            copy_text("kube/password", owner_password + "\n")
            token = secrets.token_hex(32)
            copy_text("kube/token", token + "\n")
            command("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(root / "key"), "-out", str(root / "cert"), "-days", "1", "-subj", "/CN=kubernetes.default.svc", "-addext", "subjectAltName=DNS:kubernetes.default.svc")
            (root / "cert").chmod(0o644)
            docker("cp", str(root / "key"), keeper + ":/fixture/kube/key")
            docker("cp", str(root / "cert"), keeper + ":/fixture/kube/cert")
            docker("cp", str(root / "cert"), keeper + ":/fixture/kube/ca.crt")
            copy_text("kube/server.py", '''import base64, json, ssl
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/api/v1/namespaces/jellyfin/secrets/jellyfin-admin' or self.headers.get('Authorization') != 'Bearer ' + Path('/fixture/token').read_text().strip():
            self.send_error(403); return
        body = json.dumps({'data': {'password': base64.b64encode(Path('/fixture/password').read_bytes()).decode()}}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass
server = ThreadingHTTPServer(('0.0.0.0', 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain('/fixture/cert', '/fixture/key')
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
''')
            secret_server = run("synthetic-secret", apps["sabnzbd"]["image"], "--network-alias", "kubernetes.default.svc", *mount("kube", "/fixture", True), "--entrypoint", "/lsiopy/bin/python", argv=("/fixture/server.py",), detached=True)
            run("secret-ready", initial_configure["image"], *security_options(initial_pod, initial_configure), *mount("kube", "/fixture", True), argv=("node", "-e", '''const fs = require('node:fs');
            const target = 'https://kubernetes.default.svc/api/v1/namespaces/jellyfin/secrets/jellyfin-admin';
            (async () => {
              for (let attempt = 0; attempt < 30; attempt++) {
                try {
                  const response = await fetch(target, {headers: {Authorization: 'Bearer ' + fs.readFileSync('/fixture/token', 'utf8').trim()}});
                  if (response.ok && typeof (await response.json()).data?.password === 'string') return;
                } catch {}
                await new Promise(resolve => setTimeout(resolve, 1000));
              }
              process.exitCode = 1;
            })().catch(() => { process.exitCode = 1; });'''), environment={"NODE_EXTRA_CA_CERTS": "/fixture/cert"})
            seerr_sequence = 0
            def reconcile_seerr(failure=False, periodic=False, detached=False, inputs_name="seerr-inputs", secrets_name="secrets", initial=False):
                nonlocal seerr_sequence
                seerr_sequence += 1
                job = initial_job if initial else periodic_job if periodic else seerr_job
                source_pod = job["template"]["spec"]
                source = one(source_pod["containers"], "name", "configure")
                subpaths = {
                    "configuration": inputs_name, "secrets": secrets_name,
                    "seerr-state": "seerr", "coordination": "coordination",
                    "kubernetes-api": "kube",
                }
                options = security_options(source_pod, source)
                for declared in source["volumeMounts"]:
                    options += mount(subpaths[declared["name"]], declared["mountPath"], declared.get("readOnly", False))
                environment = {item["name"]: item["value"] for item in source.get("env", [])}
                return run("seerr-reconcile-" + str(seerr_sequence), source["image"], *options,
                           argv=tuple(source["command"]), environment=environment, failure=failure, detached=detached,
                           timeout=job["activeDeadlineSeconds"])

            # Neither ready PostSync nor periodic delivery may claim pristine state.
            reconcile_seerr(failure=True)
            require(seerr_api("/settings/public") == public, "ready delivery changed unclaimed Seerr")
            reconcile_seerr(failure=True, periodic=True)
            require(seerr_api("/settings/public") == public, "periodic delivery changed unclaimed Seerr")

            copy_text("kube/password", "wrong-" + owner_password)
            reconcile_seerr(failure=True, initial=True)
            require(seerr_api("/settings/public") == public, "wrong owner credential changed unclaimed Seerr")
            copy_text("kube/password", owner_password + "\n")
            reconcile_seerr(failure=True, initial=True)  # Required Shows library is genuinely absent.
            partial_owner = seerr_api("/auth/me")
            require(seerr_api("/settings/public")["initialized"] is False and
                    partial_owner["id"] == 1 and partial_owner["jellyfinUsername"] == policy["jellyfin"]["username"],
                    "missing native library must leave the valid first owner claimed but Seerr uninitialized")
            add_library(libraries[-1])
            library_ids = verify_libraries()
            reconcile_seerr(initial=True)
            claimed_owner = seerr_api("/auth/me")
            require(claimed_owner["id"] == 1 and claimed_owner["jellyfinUsername"] == policy["jellyfin"]["username"],
                    "initial delivery did not claim the declared Jellyfin owner")
            scan = seerr_api("/settings/jellyfin/sync")
            require(scan["running"] is False and scan["progress"] > scan["total"], "fixture scan did not finish past the Movies batch with progress above the empty Shows total")

            def verify_seerr():
                owner = seerr_api("/auth/me")
                require(seerr_api("/settings/public")["initialized"] is True and
                        (owner["id"], owner["jellyfinUsername"]) == (claimed_owner["id"], claimed_owner["jellyfinUsername"]),
                        "reconciliation changed Seerr initialization or retained owner")
                enabled = {item["id"]: (item["name"], item["type"]) for item in seerr_api("/settings/jellyfin")["libraries"] if item["enabled"]}
                expected = {library_ids[item["name"]]: (item["name"], {"movies": "movie", "tvshows": "show"}[item["collectionType"]]) for item in policy["jellyfin"]["libraries"]}
                require(all(enabled.get(key) == value for key, value in expected.items()), "Seerr native library identity/type/enable mapping differs")
                result = {}
                for app in ("radarr", "sonarr"):
                    desired = policy["arr"][app]["standard"]
                    server = one(seerr_api("/settings/" + app), "name", ("Radarr" if app == "radarr" else "Sonarr") + " (Homelab)")
                    url = urlsplit(desired["url"])
                    default_name = "HD Preferred"
                    profile_id = one(api(app, "/qualityprofile"), "name", default_name)["id"]
                    expected = {"hostname": url.hostname, "port": url.port, "useSsl": url.scheme == "https", "baseUrl": url.path.rstrip("/"), "apiKey": keys[app], "activeProfileId": profile_id, "activeProfileName": default_name, "activeDirectory": desired["root"], "isDefault": True, "is4k": False, "syncEnabled": True, "preventSearch": False}
                    require(all(server.get(key) == value for key, value in expected.items()), "Seerr native Arr/profile/root/key mapping differs")
                    # Exercise Seerr's own native connection validator against real Arr.
                    request(ports["seerr"], "/api/v1/settings/" + app + "/test", key=keys["seerr"], method="POST", body=server)
                    # This is the request selector's real Arr-backed consumer,
                    # not just a readback of the settings written by our helper.
                    selector = seerr_api("/service/" + app + "/" + str(server["id"]))
                    require(selector["server"]["activeProfileId"] == profile_id and
                            selector["server"]["isDefault"] is True and selector["server"]["is4k"] is False,
                            "Seerr request selector does not default to mixed HD")
                    for name in expected_profiles[app]:
                        native_id = one(api(app, "/qualityprofile"), "name", name)["id"]
                        require(one(selector["profiles"], "name", name)["id"] == native_id,
                                "Seerr request selector lost an actual Arr profile")
                    result[app] = server
                require(verify_libraries() == library_ids, "native library identities changed")
                return result
            seerr_baseline = verify_seerr()
            docker("rm", "-f", "-v", secret_server)
            # Unmarked connections, including the generic names and a 4K tier
            # with no declared role, are UI-owned. A marked 4K connection left
            # by an earlier declared role is managed and must be removed.
            seerr_write = lambda path, method, body: request(ports["seerr"], "/api/v1" + path, key=keys["seerr"], method=method, body=body)
            unmanaged_connections = {}
            for app in ("radarr", "sonarr"):
                label = "Radarr" if app == "radarr" else "Sonarr"
                template = {key: value for key, value in seerr_baseline[app].items() if key != "id"}
                created = [seerr_write("/settings/" + app, "POST", {**template, **overrides})["id"] for overrides in (
                    {"name": label, "isDefault": False},
                    {"name": label + " 4K", "is4k": True, "isDefault": True},
                )]
                seerr_write("/settings/" + app, "POST", {**template, "name": label + " 4K (Homelab)", "is4k": True, "isDefault": False})
                unmanaged_connections[app] = [item for item in seerr_api("/settings/" + app) if item["id"] in created]
                require(len(unmanaged_connections[app]) == 2, "fixture Seerr did not retain unmanaged connections")
            reconcile_seerr()
            require(verify_seerr() == seerr_baseline, "unmanaged Seerr connections changed managed identities/state")
            seerr_connections = {}
            for app in ("radarr", "sonarr"):
                seerr_connections[app] = seerr_api("/settings/" + app)
                require([item for item in seerr_connections[app] if item["id"] != seerr_baseline[app]["id"]] == unmanaged_connections[app],
                        "reconciliation changed, deleted or kept stale unmarked/marked Seerr connections")
            copy_text("secrets/RADARR_API_KEY", keys["sonarr"] + "\n")
            reconcile_seerr(failure=True, periodic=True)
            require({app: seerr_api("/settings/" + app) for app in ("radarr", "sonarr")} == seerr_connections, "wrong Arr credential changed native Seerr connections")
            copy_text("secrets/RADARR_API_KEY", keys["radarr"] + "\n")
            reconcile_seerr(periodic=True)  # No bootstrap Secret mount or authority.
            require(verify_seerr() == seerr_baseline, "second reconcile changed native Seerr connection identities/state")

            # Pause the real Seerr API only long enough for a producer-derived
            # holder to acquire its kernel lock, then freeze that helper. The
            # native API runs normally while the other entry point is waiting:
            # it must not repair genuine settings drift until the holder exits.
            drift_policy = deepcopy(policy)
            drift_policy["seerr"]["applicationUrl"] = "https://serialized.fixture.invalid"
            copy_text("seerr-drift-inputs/seerr.json", json.dumps(drift_policy))
            copy_text("seerr-drift-inputs/seerr.mjs", cm["seerr.mjs"])
            for name in ("SEERR_API_KEY", "RADARR_API_KEY", "SONARR_API_KEY"):
                copy_text("seerr-failure-secrets/" + name, (keys["sonarr"] if name == "RADARR_API_KEY" else runtime[name]) + "\n")



            def wait_helper(container, failure=False, periodic=False):
                status = int(docker("wait", container, timeout=(periodic_job if periodic else seerr_job)["activeDeadlineSeconds"]))
                require_application_exit(status, failure, "serialized native helper")

            for failed_holder in (False, True):
                before = seerr_api("/settings/main")
                connections_before = {app: seerr_api("/settings/" + app) for app in ("radarr", "sonarr")}
                require(before["applicationUrl"] != drift_policy["seerr"]["applicationUrl"], "serialized fixture requires genuine settings drift")
                docker("pause", containers["seerr"])
                holder = reconcile_seerr(periodic=failed_holder, detached=True,
                                         secrets_name="seerr-failure-secrets" if failed_holder else "secrets")
                deadline = time.monotonic() + 10
                while not lock_held():
                    require(time.monotonic() < deadline, "native helper did not acquire the shared coordination lock")
                    time.sleep(0.05)
                docker("pause", holder)
                docker("unpause", containers["seerr"])
                waiter = reconcile_seerr(periodic=not failed_holder, detached=True, inputs_name="seerr-drift-inputs")
                waiter_pid = docker("inspect", "--format", "{{.State.Pid}}", waiter)
                require(waiter_pid.isdigit() and int(waiter_pid) > 0, "native contender has no daemon-host PID")
                # Establish that the contender has opened the actual lock
                # inode before observing native state, not merely been launched.
                deadline = time.monotonic() + 10
                while True:
                    waiting = docker("exec", lock_observer, "node", "-e", '''const fs = require('node:fs');
const pid = process.argv[1];
const inode = String(fs.statSync('/coordination/seerr.lock', {bigint: true}).ino);
const queued = fs.readFileSync('/proc/locks', 'utf8').split('\\n').some(line => {
  const row = line.trim().split(/\\s+/);
  return row[1] === '->' && row[2] === 'FLOCK' && row[5] === pid &&
    row[6].split(':').at(-1) === inode;
});
console.log(queued);''', waiter_pid)
                    if waiting == "true":
                        break
                    require(time.monotonic() < deadline, "native contender did not block on the shared coordination inode")
                    time.sleep(0.05)
                for _ in range(3):
                    require(seerr_api("/settings/main") == before, "waiting entry point changed native Seerr settings while lock held")
                    require({app: seerr_api("/settings/" + app) for app in ("radarr", "sonarr")} == connections_before, "waiting entry point changed native Seerr connections while lock held")
                    require(lock_held(), "paused native helper lost its process-owned lock")
                    time.sleep(0.1)
                docker("unpause", holder)
                wait_helper(holder, failure=failed_holder, periodic=failed_holder)
                wait_helper(waiter, periodic=not failed_holder)
                require(not lock_held(), "helper exit left the shared coordination lock held")
                require(seerr_api("/settings/main")["applicationUrl"] == drift_policy["seerr"]["applicationUrl"], "waiting native entry point did not reconcile drift after holder exit")
                require(verify_seerr() == seerr_baseline, "serialized reconciliation replaced native connection identities/state")
                reconcile_seerr(periodic=True)
                require(seerr_api("/settings/main")["applicationUrl"] == policy["seerr"]["applicationUrl"], "ordinary periodic reconciliation did not restore declared settings")
                require(verify_seerr() == seerr_baseline, "post-contention reconciliation lost native idempotence")
        finally:
            # Register resources before creation; exhaust cleanup even on timeout.
            first_error = sys.exc_info()[1]
            errors = []
            resources = [("container", name, True) for name in reversed(owned_containers)]
            resources += [("network", network, network_created), ("network", source_network, source_network_created),
                          ("volume", volume, volume_created)]
            for kind, name, attempted in resources:
                if not attempted:
                    continue
                try:
                    inspected = subprocess.run([*docker_prefix, kind, "inspect", name], capture_output=True, timeout=30, env=docker_env)
                    if inspected.returncode == 0:
                        removal = [*docker_prefix, "rm", "-f", "-v", name] if kind == "container" else [*docker_prefix, kind, "rm", name]
                        removed = subprocess.run(removal, capture_output=True, timeout=30, env=docker_env)
                        if removed.returncode:
                            errors.append("owned " + kind + " cleanup failed")
                except (OSError, subprocess.TimeoutExpired):
                    errors.append("owned " + kind + " cleanup timed out/unavailable")
            try:
                remaining = docker("container", "ls", "--all", "--filter", "name=" + network + "-", "--format", "{{.Names}}")
                require(not remaining, "owned containers remain after cleanup")
                for kind, name in (("network", network), ("network", source_network), ("volume", volume)):
                    remaining = docker(kind, "ls", "--filter", "name=" + name, "--format", "{{.Name}}")
                    require(name not in remaining.splitlines(), "owned " + kind + " remains after cleanup")
            except (AssertionError, OSError, subprocess.TimeoutExpired) as error:
                errors.append(str(error) if isinstance(error, AssertionError) else type(error).__name__)
            if errors:
                first = (str(first_error) if isinstance(first_error, AssertionError) else type(first_error).__name__) + "; " if first_error else ""
                raise AssertionError(first + "; ".join(errors))
        print("media-live-acceptance: native media APIs, permission refusals, serialized entry points/exit release, policy mutations, reconcile identities and owned cleanup passed (" + args.platform + ")")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, RuntimeError, OSError, ValueError, KeyError, HTTPError, subprocess.TimeoutExpired) as error:
        # HTTP errors and subprocess output can contain synthetic credentials;
        # report only controlled assertion labels or exception classes.
        print("media-live-acceptance: " + (str(error) if isinstance(error, AssertionError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
