#!/usr/bin/env python3
"""Exercise the rendered media policy against its pinned OCI releases in disposable Docker."""
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
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import yaml

ROOT = Path(__file__).resolve().parents[2]
MANIFESTS = ROOT / "generated/manifests/prod-home"


def command(*args, timeout=60, env=None):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout, env=env)
    if result.returncode:
        raise AssertionError(f"{args[0]} {args[1] if len(args) > 1 else ''} failed: {(result.stderr or result.stdout)[-2000:]}")
    return result.stdout.strip()


def manifest(group, name):
    return yaml.safe_load((MANIFESTS / group / name).read_text())


def image(group, name, container="main"):
    pod = manifest(group, name)["spec"]["template"]["spec"]
    return next(item["image"] for item in pod["containers"] if item["name"] == container)


def request(port, path, *, key=None, method="GET", body=None, jellyfin=False):
    headers = {"Content-Type": "application/json"}
    if key:
        headers["X-Api-Key"] = key
    if jellyfin:
        headers["Authorization"] = (
            'MediaBrowser Client="homelab-acceptance", Device="Fixture", DeviceId="fixture", Version="1"'
            + (f', Token="{key}"' if key else "")
        )
        headers.pop("X-Api-Key", None)
    payload = json.dumps(body).encode() if body is not None else None
    with urlopen(Request(f"http://127.0.0.1:{port}{path}", payload, headers, method=method), timeout=15) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


def ready(port, path, *, key=None):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            return request(port, path, key=key)
        except HTTPError as error:
            if error.code < 500:
                raise AssertionError(f"{path} returned HTTP {error.code}") from error
            time.sleep(1)
        except OSError:
            time.sleep(1)
    raise AssertionError(f"{path} did not become ready")


def main():
    if not shutil.which("docker") or not shutil.which("openssl") or not shutil.which("git"):
        raise RuntimeError("docker, openssl and git are required for the live acceptance")
    cm = manifest("media-configuration", "ConfigMap-media-configuration.yaml")["data"]
    templates = manifest("media-configuration", "ConfigMap-media-configarr-templates.yaml")["data"]
    inputs = manifest("media-configuration", "ConfigMap-media-configarr-inputs.yaml")["data"]
    job = manifest("media-configuration", "Job-media-configarr.yaml")["spec"]["template"]["spec"]
    seed_program = next(c["command"][-1] for c in job["initContainers"] if c["name"] == "seed-policy")
    configarr_container = next(c for c in job["containers"] if c["name"] == "configarr")
    configarr_image = configarr_container["image"]
    configarr_command = configarr_container["command"]
    seerr_job = manifest("media-configuration", "Job-media-config-seerr.yaml")["spec"]["template"]["spec"]
    node_image = next(c["image"] for c in seerr_job["containers"] if c["name"] == "configure")
    sab_deployment = manifest("sabnzbd", "Deployment-sabnzbd.yaml")["spec"]["template"]["spec"]
    sab_init = sab_deployment["initContainers"][0]["command"][-1]
    assert not (MANIFESTS / "gateway/HTTPRoute-requests.yaml").exists(), "initial Seerr must remain private"
    assert cm["seerr.mjs"] == (ROOT / "modules/den/aspects/kubernetes/services/seerr.mjs").read_text()

    # Docker Desktop reliably shares HOME; macOS's per-user /var/folders is not mounted.
    with tempfile.TemporaryDirectory(prefix="homelab-media-live-", dir=Path.home()) as directory:
        root = Path(directory)
        network = "homelab-media-live-" + secrets.token_hex(5)
        containers = []
        command("docker", "network", "create", network)
        try:
            def start(name, app_image, port, *mounts, aliases=(), environment=()):
                args = ["docker", "run", "-d", "--rm", "--network", network, "--name", network + "-" + name]
                for alias in aliases:
                    args += ["--network-alias", alias]
                for source, target in mounts:
                    args += ["-v", f"{source}:{target}"]
                for key, value in environment:
                    args += ["-e", f"{key}={value}"]
                args += ["-p", f"127.0.0.1::{port}", app_image]
                container = command(*args, timeout=120)
                containers.append(container)
                return int(command("docker", "port", container, f"{port}/tcp").rsplit(":", 1)[-1])

            media = root / "media"
            for path in ("library/movies", "library/tv", "library/movies-ui", "downloads/usenet/incomplete", "downloads/usenet/complete"):
                (media / path).mkdir(parents=True)
            sentinel = media / "library/movies-ui/sentinel.mkv"
            sentinel.write_bytes(b"root record removal must not remove media\n")
            ports = {}
            images = {
                "radarr": image("radarr", "Deployment-radarr.yaml"),
                "sonarr": image("sonarr", "Deployment-sonarr.yaml"),
                "prowlarr": image("prowlarr", "Deployment-prowlarr.yaml"),
                "sabnzbd": image("sabnzbd", "Deployment-sabnzbd.yaml"),
                "seerr": image("seerr", "StatefulSet-seerr.yaml"),
                "jellyfin": image("jellyfin", "Deployment-jellyfin.yaml", "jellyfin"),
            }
            for app, port in (("radarr", 7878), ("sonarr", 8989), ("prowlarr", 9696)):
                state = root / app
                state.mkdir()
                ports[app] = start(app, images[app], port, (state, "/config"), (media, "/data"),
                                   aliases=(app + ".media.svc",), environment=(("PUID", "1000"), ("PGID", "1000"), ("TZ", "UTC")))
            keys = {}
            for app in ("radarr", "sonarr", "prowlarr"):
                deadline = time.monotonic() + 120
                config = root / app / "config.xml"
                import xml.etree.ElementTree as ET
                while time.monotonic() < deadline:
                    try:
                        keys[app] = ET.parse(config).getroot().findtext("ApiKey")
                        if keys[app]:
                            break
                    except (OSError, ET.ParseError):
                        pass
                    time.sleep(1)
                assert keys.get(app), f"{app} did not create its API key"
                ready(ports[app], f"/api/v{1 if app == 'prowlarr' else 3}/system/status", key=keys[app])

            app_api = lambda path, method="GET", body=None: request(ports["prowlarr"], "/api/v1" + path, key=keys["prowlarr"], method=method, body=body)
            unmanaged = app_api("/applications", "POST", {
                "name": "UI-owned Radarr", "implementation": "Radarr", "configContract": "RadarrSettings",
                "syncLevel": "addOnly", "tags": [], "fields": [
                    {"name": "prowlarrUrl", "value": "http://prowlarr.media.svc:9696"},
                    {"name": "baseUrl", "value": "http://radarr.media.svc:7878"},
                    {"name": "apiKey", "value": keys["radarr"]},
                ],
            })
            radarr_api = lambda path, method="GET", body=None: request(ports["radarr"], "/api/v3" + path, key=keys["radarr"], method=method, body=body)
            radarr_api("/rootfolder", "POST", {"path": "/data/library/movies-ui"})

            sab_key, sab_user, sab_password = (secrets.token_hex(24) for _ in range(3))
            sab_config = root / "sabnzbd"
            sab_config.mkdir()
            required = json.loads(re.search(r"for key in (\[.*?\]):", sab_init).group(1))
            env = {"SABNZBD_API_KEY": sab_key, "SABNZBD_USERNAME": sab_user, "SABNZBD_PASSWORD": sab_password}
            env.update({name: "synthetic-provider-credential" for name in required if name not in env})
            init_args = ["docker", "run", "--rm", "-v", f"{sab_config}:/config", "-v", f"{media}:/data"]
            for name in env:
                init_args += ["-e", name]
            command(*init_args, "--entrypoint", "/lsiopy/bin/python", images["sabnzbd"], "-c", sab_init,
                    timeout=120, env={**os.environ, **env})
            ports["sabnzbd"] = start("sabnzbd", images["sabnzbd"], 8080, (sab_config, "/config"), (media, "/data"),
                                     aliases=("sabnzbd.media.svc",), environment=(("PUID", "1000"), ("PGID", "1000")))
            ready(ports["sabnzbd"], "/api?mode=version&output=json&apikey=" + sab_key)
            sab_container = containers[-1]

            configarr = root / "configarr"
            for subdir in ("config", "templates", "seed", "repos"):
                (configarr / subdir).mkdir(parents=True)
            (configarr / "config/config.yml").write_text(cm["config.yml"])
            for name, contents in templates.items():
                (configarr / "templates" / name).write_text(contents)
            for name, contents in inputs.items():
                (configarr / "seed" / name).write_text(contents)
            command("sh", "-ec", seed_program.replace("/app/repos", str(configarr / "repos")).replace("/seed", str(configarr / "seed")), timeout=60)
            config_env = {"RADARR_API_KEY": keys["radarr"], "SONARR_API_KEY": keys["sonarr"],
                          "PROWLARR_API_KEY": keys["prowlarr"], **env}

            def reconcile_configarr(expect_failure=None, config_location=None):
                args = ["docker", "run", "--rm", "--network", network,
                        "-v", f"{configarr / 'config'}:/app/config:ro", "-v", f"{configarr / 'templates'}:/app/templates:ro",
                        "-v", f"{configarr / 'repos'}:/app/repos"]
                for name in config_env:
                    args += ["-e", name]
                for name in ("STOP_ON_ERROR", "CONFIGARR_ENFORCE_CONFIG_VALIDATION", "CONFIGARR_ENFORCE_EXTERNAL_VALIDATION"):
                    args += ["-e", name + "=true"]
                if config_location:
                    args += ["-e", "CONFIG_LOCATION=" + config_location]
                if expect_failure:
                    result = subprocess.run([*args, configarr_image, *configarr_command], timeout=180, text=True,
                                            capture_output=True, env={**os.environ, **config_env})
                    assert result.returncode and expect_failure in result.stdout, (
                        f"Failed policy or API write was reported as a successful Job: status={result.returncode}, "
                        f"output={result.stdout[-500:]}, stderr={result.stderr[-500:]}"
                    )
                    return
                return command(*args, configarr_image, *configarr_command, timeout=180,
                               env={**os.environ, **config_env})
            (configarr / "config/invalid.yml").write_text("radarr: [broken\n")
            reconcile_configarr(expect_failure="YAMLParseError", config_location="/app/config/invalid.yml")

            reconcile_configarr()
            policy = json.loads(cm["seerr.json"])
            for app in ("radarr", "sonarr"):
                profile = policy["arr"][app]["standard"]["profile"]
                api = lambda path: request(ports[app], "/api/v3" + path, key=keys[app])
                assert any(item["name"] == profile and item["formatItems"] for item in api("/qualityprofile"))
                assert [item["path"] for item in api("/rootfolder")] == [policy["arr"][app]["standard"]["root"]]
                assert any(item["name"] == "SABnzbd (Homelab)" for item in api("/downloadclient"))
            assert sentinel.read_bytes() == b"root record removal must not remove media\n"
            apps = app_api("/applications")
            assert {item["name"] for item in apps} == {"UI-owned Radarr", "homelab-radarr", "homelab-sonarr"}
            assert next(item for item in apps if item["name"] == "UI-owned Radarr")["id"] == unmanaged["id"]
            before = {app: {path: request(ports[app], "/api/v3" + path, key=keys[app])
                            for path in ("/rootfolder", "/qualityprofile", "/customformat", "/downloadclient")}
                      for app in ("radarr", "sonarr")}
            reconcile_configarr()
            for app in ("radarr", "sonarr"):
                for path, values in before[app].items():
                    after = request(ports[app], "/api/v3" + path, key=keys[app])
                    stable = lambda items: [{key: value for key, value in item.items() if key != "freeSpace"} for item in items]
                    assert stable(after) == stable(values), (app, path)
            assert app_api("/applications") == apps
            command("docker", "rm", "-f", sab_container)
            containers.remove(sab_container)
            env["SABNZBD_USERNAME"] = "rotated-" + secrets.token_hex(8)
            config_env["SABNZBD_USERNAME"] = env["SABNZBD_USERNAME"]
            reconcile_configarr(expect_failure="ERROR ")
            command(*init_args, "--entrypoint", "/lsiopy/bin/python", images["sabnzbd"], "-c", sab_init,
                    timeout=120, env={**os.environ, **env})
            ports["sabnzbd"] = start("sabnzbd", images["sabnzbd"], 8080, (sab_config, "/config"), (media, "/data"),
                                     aliases=("sabnzbd.media.svc",), environment=(("PUID", "1000"), ("PGID", "1000")))
            ready(ports["sabnzbd"], "/api?mode=version&output=json&apikey=" + sab_key)
            reconcile_configarr()
            for app in ("radarr", "sonarr"):
                clients = request(ports[app], "/api/v3/downloadclient", key=keys[app])
                sab = next(client for client in clients if client["name"] == "SABnzbd (Homelab)")
                assert next(field["value"] for field in sab["fields"] if field["name"] == "username") == env["SABNZBD_USERNAME"]
                assert sab["id"] == next(client["id"] for client in before[app]["/downloadclient"]
                                         if client["name"] == "SABnzbd (Homelab)")
                commands = request(ports[app], "/api/v3/command", key=keys[app])
                assert not any("search" in item["name"].lower() or "upgrade" in item["name"].lower()
                               for item in commands), (app, commands)
            assert app_api("/applications") == apps

            jf_config = root / "jellyfin"
            jf_config.mkdir()
            movies = root / "movies"
            movies.mkdir()
            ports["jellyfin"] = start("jellyfin", images["jellyfin"], 8096, (jf_config, "/config"), (movies, "/media/movies:ro"),
                                      aliases=("jellyfin.jellyfin.svc.cluster.local",))
            ready(ports["jellyfin"], "/Users/Public")
            owner_password = secrets.token_hex(24)
            def jellyfin(path, method="GET", body=None, key=None):
                return request(ports["jellyfin"], path, key=key, method=method, body=body,
                               jellyfin=not path.startswith("/Startup/"))
            assert jellyfin("/System/Info/Public")["StartupWizardCompleted"] is False
            assert ready(ports["jellyfin"], "/Startup/User")["Name"]
            jellyfin("/Startup/Configuration", "POST", {"UICulture": "en-US", "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en"})
            assert jellyfin("/Startup/User")["Name"]
            jellyfin("/Startup/User", "POST", {"Name": "daniel", "Password": owner_password})
            jellyfin("/Startup/Complete", "POST", {})
            owner_token = jellyfin("/Users/AuthenticateByName", "POST", {"Username": "daniel", "Pw": owner_password})["AccessToken"]
            jellyfin("/Library/VirtualFolders?" + urlencode({"name": "Movies", "collectionType": "movies", "refreshLibrary": "false"}),
                     "POST", {"LibraryOptions": {"PathInfos": [{"Path": "/media/movies"}]}}, key=owner_token)

            seerr_key = secrets.token_hex(32)
            seerr_config = root / "seerr"
            seerr_config.mkdir()
            ports["seerr"] = start("seerr", images["seerr"], 5055, (seerr_config, "/app/config"),
                                   aliases=("seerr.media.svc",), environment=(("API_KEY", seerr_key),))
            public = ready(ports["seerr"], "/api/v1/settings/public")
            assert public["mediaServerType"] == 4 and public["initialized"] is False
            assert json.loads((seerr_config / "settings.json").read_text())["jellyfin"]["ip"] == ""

            kube = root / "kube"
            kube.mkdir()
            (kube / "password").write_text(owner_password + "\n")
            token = secrets.token_hex(20)
            (kube / "token").write_text(token + "\n")
            command("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(kube / "key"),
                    "-out", str(kube / "cert"), "-days", "1", "-subj", "/CN=kubernetes.default.svc",
                    "-addext", "subjectAltName=DNS:kubernetes.default.svc", timeout=30)
            (kube / "server.py").write_text('''import base64, json, ssl
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
            kube_container = command("docker", "run", "-d", "--rm", "--network", network,
                                     "--network-alias", "kubernetes.default.svc", "-v", f"{kube}:/fixture:ro",
                                     "--entrypoint", "python3", images["sabnzbd"], "/fixture/server.py")
            containers.append(kube_container)
            seerr_inputs = root / "seerr-inputs"
            seerr_inputs.mkdir()
            (seerr_inputs / "seerr.json").write_text(cm["seerr.json"])
            (seerr_inputs / "seerr.mjs").write_text(cm["seerr.mjs"])
            seerr_secrets = root / "seerr-secrets"
            seerr_secrets.mkdir()
            for name, value in (("SEERR_API_KEY", seerr_key), ("RADARR_API_KEY", keys["radarr"]), ("SONARR_API_KEY", keys["sonarr"])):
                (seerr_secrets / name).write_text(value + "\n")

            def reconcile_seerr():
                return command("docker", "run", "--rm", "--network", network, "-v", f"{seerr_inputs}:/configuration:ro",
                               "-v", f"{seerr_secrets}:/secrets:ro", "-v", f"{seerr_config}:/seerr-state:ro",
                               "-v", f"{kube / 'token'}:/var/run/secrets/kubernetes.io/serviceaccount/token:ro",
                               "-v", f"{kube / 'cert'}:/fixture/cert:ro", "-e", "NODE_EXTRA_CA_CERTS=/fixture/cert",
                               node_image, "node", "/configuration/seerr.mjs", timeout=240)

            assert "reconciled" in reconcile_seerr()
            seerr_api = lambda path: request(ports["seerr"], "/api/v1" + path, key=seerr_key)
            assert seerr_api("/settings/public")["initialized"] is True
            assert seerr_api("/auth/me")["id"] == 1
            assert any(item["name"] == "Movies" and item["enabled"] for item in seerr_api("/settings/jellyfin")["libraries"])
            for app in ("radarr", "sonarr"):
                server = seerr_api("/settings/" + app)
                assert len(server) == 1 and server[0]["isDefault"] and not server[0]["is4k"]
                assert server[0]["activeProfileName"] == policy["arr"][app]["standard"]["profile"]
            command("docker", "rm", "-f", kube_container)
            containers.remove(kube_container)
            assert "reconciled" in reconcile_seerr(), "steady-state Seerr must need only its stable API key"
            assert sentinel.read_bytes() == b"root record removal must not remove media\n"
            print("media-live-acceptance: pinned Configarr, Arr, Prowlarr, SAB, Seerr and Jellyfin passed")
        finally:
            for container in reversed(containers):
                subprocess.run(["docker", "rm", "-f", container], capture_output=True, timeout=30)
            subprocess.run(["docker", "network", "rm", network], capture_output=True, timeout=30)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"media-live-acceptance: {error}", file=sys.stderr)
        sys.exit(1)
