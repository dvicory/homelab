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
    require(actual_qualities == expected_qualities, "native allowed qualities/group membership differ")
    actual_formats = api("/customformat")
    scores = {item["format"]: item["score"] for item in profile["formatItems"]}
    identities = {}
    for name, trash_id in desired["formatItems"].items():
        expected = formats[trash_id]
        actual = one(actual_formats, "name", name)
        require(actual["includeCustomFormatWhenRenaming"] == expected["includeCustomFormatWhenRenaming"], "native custom format rename behavior differs")
        require(specifications(actual["specifications"]) == specifications(expected["specifications"]), "native custom format identity/specifications differ: " + name)
        require(scores.get(actual["id"]) == expected["trash_scores"]["default"], "native custom format score differs: " + name)
        identities[trash_id] = actual["id"]
    return profile["id"], identities


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
        # s6-notifyoncheck can also mention the daemon in its argv.
        if not marker.endswith(".py") and status.get("Name", "").strip() != Path(marker).name:
            continue
        if "Uid" in status:
            matches.append((tuple(map(int, status["Uid"].split())), tuple(map(int, status["Gid"].split())), set(map(int, status["Groups"].split()))))
    require(len(matches) == 1, "cannot uniquely identify actual " + marker + " daemon")
    uid, gid, groups = matches[0]
    require(set(uid) == {expected[0]} and set(gid) == {expected[1]}, f"{marker} daemon UID/GID differs: {uid}/{gid}")
    require(set(expected[2]) <= groups, f"{marker} daemon loses declared supplemental groups: actual={sorted(groups)}, required={expected[2]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker-host", required=True, help="explicit local unix:// Docker socket")
    parser.add_argument("--platform", default="linux/amd64", choices=("linux/amd64", "linux/arm64"))
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
    templates = manifest("media-configuration", "ConfigMap-media-configarr-templates.yaml")["data"]
    inputs = manifest("media-configuration", "ConfigMap-media-configarr-inputs.yaml")["data"]
    configarr_pod = pod("media-configuration", "Job-media-configarr.yaml")
    configarr = one(configarr_pod["containers"], "name", "configarr")
    seed = one(configarr_pod["initContainers"], "name", "seed-policy")
    seerr_pod = pod("media-configuration", "Job-media-config-seerr.yaml")
    configure = one(seerr_pod["containers"], "name", "configure")
    pods = {app: pod(app, f"Deployment-{app}.yaml") for app in ("radarr", "sonarr", "prowlarr", "sabnzbd", "jellyfin")}
    pods["seerr"] = pod("seerr", "StatefulSet-seerr.yaml")
    apps = {app: one(value["containers"], "name", "jellyfin" if app == "jellyfin" else "main") for app, value in pods.items()}
    for container in (*apps.values(), configarr, configure):
        require("@sha256:" in container["image"], "native scenario requires digest-pinned images")
    identities = {}
    for app, container in apps.items():
        declared = {item["name"]: item["value"] for item in container.get("env", []) if "value" in item}
        security = {**pods[app].get("securityContext", {}), **container.get("securityContext", {})}
        identities[app] = (int(security.get("runAsUser", declared.get("PUID", 0))), int(security.get("runAsGroup", declared.get("PGID", 0))), security.get("supplementalGroups", []))
    media_gid, = identities["radarr"][2]
    for app in ("sonarr", "sabnzbd", "jellyfin"):
        require(identities[app][2] == [media_gid], "shared media group declarations differ")
    expected_profiles = {app: json.loads((ROOT / "assets/media-policy" / f"{app}-{policy['arr'][app]['standard']['bundle']}.json").read_text()) for app in ("radarr", "sonarr")}
    expected_formats = {app: {value["trash_id"]: value for name, text in inputs.items() if name.startswith(app + "-cf-") for value in [json.loads(text)]} for app in ("radarr", "sonarr")}
    libraries = json.loads(manifest("jellyfin-configuration", "ConfigMap-jellarr-configuration.yaml")["data"]["config.yml"])["library"]["virtualFolders"]
    keys = {app: secrets.token_hex(32) for app in ("radarr", "sonarr", "prowlarr", "seerr")}
    sab_init = pods["sabnzbd"]["initContainers"][0]["command"][-1]
    runtime = {app.upper() + "_API_KEY": value for app, value in keys.items()}
    runtime.update({"SABNZBD_API_KEY": secrets.token_hex(32), "SABNZBD_USERNAME": secrets.token_hex(24), "SABNZBD_PASSWORD": secrets.token_hex(24)})
    for name in json.loads(re.search(r"for key in (\[.*?\]):", sab_init).group(1)):
        runtime.setdefault(name, "synthetic-provider-credential")
    network = "homelab-media-live-" + secrets.token_hex(6)
    volume = network + "-fixture"
    owned_containers = []
    network_created = volume_created = False
    with tempfile.TemporaryDirectory(prefix=network + "-", dir=Path.home()) as directory:
        root = Path(directory)
        try:
            network_created = True
            docker("network", "create", "--internal", network)
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
                parameters = [*docker_prefix, "run", "--rm", "--name", container, "--platform", args.platform, "--network", network]
                if detached:
                    parameters.append("-d")
                parameters.extend(options)
                env = {**docker_env, **(environment or {})}
                for key in environment or {}:
                    parameters += ["-e", key]
                result = subprocess.run([*parameters, image, *argv], capture_output=True, text=True, timeout=timeout, env=env)
                require(result.returncode != 0 if failure else result.returncode == 0, f"{name} {'unexpectedly succeeded' if failure else 'failed'} (exit {result.returncode})")
                return container

            # A root setup helper owns only this new Linux volume. Application
            # daemons retain production entrypoints, IDs and supplemental groups.
            keeper = run("fixture", apps["sabnzbd"]["image"], "-v", volume + ":/fixture", "--entrypoint", "/lsiopy/bin/python", argv=("-c", "import time; time.sleep(86400)"), detached=True)
            request = partial(request_from_container, docker, keeper)
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
for name in ['config', 'templates', 'seed', 'repos', 'seerr-inputs', 'secrets', 'kube']:
    p = root / name; p.mkdir(); os.chown(p, 1000, 1000); p.chmod(0o755)
''', json.dumps(setup))

            def copy_text(subpath, content):
                source = root / "payload"
                source.write_text(content)
                source.chmod(0o644)
                docker("cp", str(source), keeper + ":/fixture/" + subpath)

            copy_text("config/config.yml", cm["config.yml"])
            copy_text("config/invalid.yml", "radarr: [broken\n")
            for name, text in templates.items():
                copy_text("templates/" + name, text)
            for name, text in inputs.items():
                copy_text("seed/" + name, text)
            run("seed", seed["image"], *security_options(configarr_pod, seed), *mount("seed", "/seed", True), *mount("repos", "/app/repos"), argv=tuple(seed["command"]))
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
                ui_format = deepcopy(next(iter(expected_formats[app].values())))
                ui_format = {key: value for key, value in ui_format.items() if key in ("name", "includeCustomFormatWhenRenaming", "specifications")}
                ui_format["name"] = "UI-owned custom format"
                for item in ui_format["specifications"]:
                    item["fields"] = [{"name": key, "value": value} for key, value in item["fields"].items()]
                unmanaged_formats[app] = call("/customformat", "POST", ui_format)
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
            denied(lambda: request(ports["sabnzbd"], "/api?" + urlencode({"mode": "get_config", "output": "json", "apikey": keys["radarr"]})), statuses=(403,))

            sequence = 0
            def reconcile_configarr(failure=False, overrides=None):
                nonlocal sequence
                sequence += 1
                environment = {item["name"]: item.get("value", runtime.get(item.get("valueFrom", {}).get("secretKeyRef", {}).get("key"))) for item in configarr["env"]}
                environment.update(overrides or {})
                run("configarr-" + str(sequence), configarr["image"], *security_options(configarr_pod, configarr), *mount("config", "/app/config", True), *mount("templates", "/app/templates", True), *mount("repos", "/app/repos"), argv=tuple(configarr["command"]), environment=environment, failure=failure)

            def verify_arr(app):
                desired = policy["arr"][app]["standard"]
                call = lambda path: api(app, path)
                require([item["path"] for item in call("/rootfolder")] == [desired["root"]], "native managed root folders differ")
                verify_profile(call, expected_profiles[app], expected_formats[app])
                unmanaged = call("/qualityprofile/" + str(unmanaged_profiles[app]["id"]))
                require({key: value for key, value in unmanaged.items() if key != "formatItems"} == {key: value for key, value in unmanaged_profiles[app].items() if key != "formatItems"}, "unmanaged quality profile changed")
                old_scores = {item["format"]: item["score"] for item in unmanaged_profiles[app]["formatItems"]}
                actual_scores = {item["format"]: item["score"] for item in unmanaged["formatItems"]}
                require(all(actual_scores.get(key) == value for key, value in old_scores.items()), "unmanaged profile scores changed")
                require(call("/customformat/" + str(unmanaged_formats[app]["id"])) == unmanaged_formats[app], "unmanaged custom format changed")
                client = one(call("/downloadclient"), "name", "SABnzbd (Homelab)")
                require(client["implementation"] == "Sabnzbd" and client["enable"] is True, "native SAB client not enabled")
                values = fields(client)
                expected = {"host": policy["sab"]["host"], "port": policy["sab"]["port"], "useSsl": False, "urlBase": "", "username": runtime["SABNZBD_USERNAME"], "movieCategory" if app == "radarr" else "tvCategory": desired["category"]}
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
            unmanaged_library = {"name": "UI-owned library", "collectionType": "movies", "libraryOptions": {"pathInfos": [{"path": "/media/movies-ui"}]}}
            add_library(unmanaged_library)
            jellyfin("/Library/Refresh", "POST", key=owner_token)
            deadline = time.monotonic() + 180
            preserved_item = None
            while time.monotonic() < deadline:
                items = jellyfin("/Items?Recursive=true&Fields=Path&IncludeItemTypes=Movie", key=owner_token)["Items"]
                matches = [item for item in items if item.get("Path") == "/media/movies-ui/Fixture.mp4"]
                if len(matches) == 1:
                    preserved_item = matches[0]["Id"]; break
                time.sleep(2)
            require(preserved_item is not None, "Jellyfin daemon could not read unmanaged legal media")
            stream_path = "/Videos/" + preserved_item + "/stream.mp4?Static=true"
            preserved_digest = hashlib.sha256(jellyfin(stream_path, key=owner_token, binary=True)).digest()
            def verify_preserved():
                require(hashlib.sha256(jellyfin(stream_path, key=owner_token, binary=True)).digest() == preserved_digest, "Jellyfin daemon cannot serve preserved unmanaged media")

            reconcile_configarr(failure=True, overrides={"CONFIG_LOCATION": "/app/config/invalid.yml"})
            reconcile_configarr()
            for app in ("radarr", "sonarr"):
                verify_arr(app)
            verify_prowlarr()
            baseline = arr_snapshot()
            prowlarr_ids = {item["name"]: item["id"] for item in api("prowlarr", "/applications")}
            reconcile_configarr()
            require(arr_snapshot() == baseline, "second reconcile changed native Arr identities/state")
            verify_prowlarr()
            require({item["name"]: item["id"] for item in api("prowlarr", "/applications")} == prowlarr_ids, "second reconcile changed Prowlarr identities")
            reconcile_configarr(failure=True, overrides={"SONARR_API_KEY": keys["radarr"]})
            require(arr_snapshot() == baseline, "wrong native credential changed Arr state")
            for app in ("radarr", "sonarr"):
                profile = one(api(app, "/qualityprofile"), "name", expected_profiles[app]["name"])
                wrong = deepcopy(profile)
                owned_id = verify_profile(lambda path: api(app, path), expected_profiles[app], expected_formats[app])[1][next(iter(expected_profiles[app]["formatItems"].values()))]
                one(wrong["formatItems"], "format", owned_id)["score"] += 1
                api(app, "/qualityprofile/" + str(profile["id"]), "PUT", wrong)
                rejected(lambda: verify_arr(app), "wrong native custom format score")
                reconcile_configarr()
                verify_arr(app)
                require(arr_snapshot() == baseline, "score repair replaced native identities or unmanaged state")
            root_record = api("sonarr", "/rootfolder")[0]
            api("sonarr", "/rootfolder/" + str(root_record["id"]), "DELETE")
            rejected(lambda: verify_arr("sonarr"), "missing native root folder")
            reconcile_configarr()
            verify_arr("sonarr")
            rotated_baseline = arr_snapshot()
            docker("rm", "-f", containers["sabnzbd"])
            runtime["SABNZBD_USERNAME"] = "rotated-" + secrets.token_hex(12)
            reconcile_configarr(failure=True)
            require(arr_snapshot() == rotated_baseline, "failed SAB handshake persisted rotated credentials")
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
            docker("cp", str(root / "key"), keeper + ":/fixture/kube/key")
            docker("cp", str(root / "cert"), keeper + ":/fixture/kube/cert")
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
            run("secret-ready", configure["image"], *mount("kube", "/fixture", True), argv=("node", "-e", '''const fs = require('node:fs');
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
            def reconcile_seerr(failure=False):
                nonlocal seerr_sequence
                seerr_sequence += 1
                run("seerr-reconcile-" + str(seerr_sequence), configure["image"], *security_options(seerr_pod, configure), *mount("seerr-inputs", "/configuration", True), *mount("secrets", "/secrets", True), *mount("seerr", "/seerr-state", True), *mount("kube", "/var/run/secrets/kubernetes.io/serviceaccount", True), *mount("kube", "/fixture", True), argv=tuple(configure["command"]), environment={"NODE_EXTRA_CA_CERTS": "/fixture/cert"}, failure=failure)

            copy_text("kube/password", "wrong-" + owner_password)
            reconcile_seerr(failure=True)
            require(seerr_api("/settings/public")["initialized"] is False, "wrong owner credential initialized Seerr")
            copy_text("kube/password", owner_password + "\n")
            reconcile_seerr(failure=True)  # Required Shows library is genuinely absent.
            require(seerr_api("/settings/public")["initialized"] is False, "missing native library initialized Seerr")
            add_library(libraries[-1])
            library_ids = verify_libraries()
            reconcile_seerr()

            def verify_seerr():
                require(seerr_api("/settings/public")["initialized"] is True and seerr_api("/auth/me")["id"] == 1, "Seerr owner/initialization state differs")
                enabled = {item["id"]: (item["name"], item["type"]) for item in seerr_api("/settings/jellyfin")["libraries"] if item["enabled"]}
                expected = {library_ids[item["name"]]: (item["name"], {"movies": "movie", "tvshows": "show"}[item["collectionType"]]) for item in policy["jellyfin"]["libraries"]}
                require(all(enabled.get(key) == value for key, value in expected.items()), "Seerr native library identity/type/enable mapping differs")
                result = {}
                for app in ("radarr", "sonarr"):
                    desired = policy["arr"][app]["standard"]
                    server = one(seerr_api("/settings/" + app), "name", "Radarr" if app == "radarr" else "Sonarr")
                    url = urlsplit(desired["url"])
                    profile_id = one(api(app, "/qualityprofile"), "name", desired["profile"])["id"]
                    expected = {"hostname": url.hostname, "port": url.port, "useSsl": url.scheme == "https", "baseUrl": url.path.rstrip("/"), "apiKey": keys[app], "activeProfileId": profile_id, "activeProfileName": desired["profile"], "activeDirectory": desired["root"], "isDefault": True, "is4k": False, "syncEnabled": True, "preventSearch": False}
                    require(all(server.get(key) == value for key, value in expected.items()), "Seerr native Arr/profile/root/key mapping differs")
                    # Exercise Seerr's own native connection validator against real Arr.
                    request(ports["seerr"], "/api/v1/settings/" + app + "/test", key=keys["seerr"], method="POST", body=server)
                    result[app] = server
                require(verify_libraries() == library_ids, "native library identities changed")
                return result
            seerr_baseline = verify_seerr()
            copy_text("secrets/RADARR_API_KEY", keys["sonarr"] + "\n")
            reconcile_seerr(failure=True)
            require({app: seerr_api("/settings/" + app) for app in ("radarr", "sonarr")} == {app: [value] for app, value in seerr_baseline.items()}, "wrong Arr credential changed native Seerr connections")
            copy_text("secrets/RADARR_API_KEY", keys["radarr"] + "\n")
            docker("rm", "-f", secret_server)
            reconcile_seerr()  # Steady state must not need the bootstrap Secret.
            require(verify_seerr() == seerr_baseline, "second reconcile changed native Seerr connection identities/state")
        finally:
            # Register resources before creation; exhaust cleanup even on timeout.
            first_error = sys.exc_info()[1]
            errors = []
            resources = [("container", name, True) for name in reversed(owned_containers)]
            resources += [("network", network, network_created), ("volume", volume, volume_created)]
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
                for kind, name in (("network", network), ("volume", volume)):
                    remaining = docker(kind, "ls", "--filter", "name=" + name, "--format", "{{.Name}}")
                    require(name not in remaining.splitlines(), "owned " + kind + " remains after cleanup")
            except (AssertionError, OSError, subprocess.TimeoutExpired) as error:
                errors.append(str(error) if isinstance(error, AssertionError) else type(error).__name__)
            if errors:
                first = (str(first_error) if isinstance(first_error, AssertionError) else type(first_error).__name__) + "; " if first_error else ""
                raise AssertionError(first + "; ".join(errors))
        print("media-live-acceptance: native media APIs, permission refusals, policy mutations, reconcile identities and owned cleanup passed (" + args.platform + ")")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, RuntimeError, OSError, ValueError, KeyError, HTTPError, subprocess.TimeoutExpired) as error:
        # HTTP errors and subprocess output can contain synthetic credentials;
        # report only controlled assertion labels or exception classes.
        print("media-live-acceptance: " + (str(error) if isinstance(error, AssertionError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
