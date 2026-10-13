#!/usr/bin/env python3
"""Household sign-in acceptance: Kanidm LDAPS, Jellyfin's LDAP plugin, Seerr.

Runs in an exclusive disposable native x86 Docker fixture. Every workload
uses the image, command, environment and configuration of the committed prod-home
manifests. Test-only pieces: Docker instead of Kubernetes, a test CA that
Kanidm's clients trust through SSL_CERT_FILE (production uses a public CA),
and provisioning without OAuth2 clients, whose Secret publication needs
Kubernetes; identity-provision-runtime covers those. The operator and user
steps follow docs/operations/identity.md. Credentials are generated here and
never printed.
"""
import argparse
import hashlib
import hmac
import http.cookiejar
import json
import os
import secrets
import shutil
import ssl
import struct
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
MANIFESTS = ROOT / "generated/manifests/prod-home"
WORK = Path("/root/household")
LDAP_PROVIDER = "Jellyfin.Plugin.LDAP_Auth.LdapAuthenticationProviderPlugin"
DEFAULT_PROVIDER = "Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider"
JELLYFIN_HOST = "jellyfin.jellyfin.svc.cluster.local"


def require(condition, label, detail=None):
    if not condition:
        raise AssertionError(f"{label}: {json.dumps(detail, default=str)[:600]}")
    print(f"ok - {label}", flush=True)


def evidence(label, value):
    print(f"EVIDENCE {label} {json.dumps(value, sort_keys=True, default=str)}", flush=True)


def run(*args, check=True, timeout=900, input=None):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout, input=input)
    if check and result.returncode != 0:
        raise RuntimeError(f"{args[0]} {args[1] if len(args) > 1 else ''} failed (exit {result.returncode}); output withheld")
    return result


def manifest(group, name):
    return yaml.safe_load((MANIFESTS / group / name).read_text())


def container(pod, name, init=False):
    items = pod["initContainers" if init else "containers"]
    return next(item for item in items if item["name"] == name)


def environment(spec):
    return [arg for item in spec.get("env", []) for arg in ("-e", f"{item['name']}={item['value']}")]


class Http:
    def __init__(self, base, cafile=None, cookies=False):
        self.base = base
        handlers = [urllib.request.ProxyHandler({})]
        if cafile:
            handlers.append(urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=cafile)))
        if cookies:
            handlers.append(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.opener = urllib.request.build_opener(*handlers)

    def call(self, method, path, body=None, headers=None):
        headers = dict(headers or {})
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with self.opener.open(request, timeout=60) as response:
                status, reply, payload = response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            status, reply, payload = error.code, error.headers, error.read()
        except (urllib.error.URLError, OSError):
            return 0, {}, None
        try:
            parsed = json.loads(payload) if payload.strip() else None
        except ValueError:
            parsed = payload.decode("utf-8", errors="replace")
        return status, reply, parsed


def wait(check, label, deadline=300):
    end = time.time() + deadline
    while time.time() < end:
        try:
            if check():
                return
        except Exception:
            pass
        time.sleep(2)
    raise AssertionError(f"{label} not ready")


def totp(secret, algo, digits, step):
    counter = struct.pack(">Q", int(time.time()) // step)
    digest = hmac.new(bytes(secret), counter, getattr(hashlib, algo)).digest()
    offset = digest[-1] & 0x0F
    return (struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF) % (10**digits)


class Kanidm:
    def __init__(self, domain, cafile):
        self.http = Http(f"https://{domain}", cafile=cafile)
        self.admin = None

    def api(self, method, path, body=None, token=None):
        status, _, payload = self.http.call(method, path, body, token or self.admin)
        return status, payload

    def login(self, name, password, otp=None):
        status, reply, payload = self.http.call("POST", "/v1/auth", {"step": {"init": name}})
        if status != 200:
            evidence("kanidm-auth", {"name": name, "init_http": status, "authenticated": False})
            return None
        session = {"X-KANIDM-AUTH-SESSION-ID": reply["X-KANIDM-AUTH-SESSION-ID"]}
        mech = "passwordmfa" if otp else "password"
        if mech not in payload["state"].get("choose", []):
            evidence("kanidm-auth", {"name": name, "init_http": status, "offered": payload["state"].get("choose"), "authenticated": False})
            return None
        status, _, payload = self.http.call("POST", "/v1/auth", {"step": {"begin": mech}}, session)
        require(status == 200, "authentication mechanism starts", status)
        result = self._steps(session, payload["state"], password, otp)
        evidence("kanidm-auth", {"name": name, "mechanism": mech, "authenticated": result is not None})
        return result

    def _steps(self, session, state, password, otp):
        while "continue" in state:
            credential = {"totp": totp(**otp)} if "totp" in state["continue"] else {"password": password}
            _, _, payload = self.http.call("POST", "/v1/auth", {"step": {"cred": credential}}, session)
            state = payload["state"]
        return {"Authorization": "Bearer " + state["success"]} if "success" in state else None

    def reauth(self, token, password, otp):
        # Writing one's own POSIX password needs a privileged session, which the
        # kanidm CLI obtains the same way.
        if otp:
            time.sleep(otp["step"] - time.time() % otp["step"] + 1)
        status, reply, payload = self.http.call("POST", "/v1/reauth", "token", token)
        require(status == 200, "reauthentication starts", status)
        session = dict(token, **{"X-KANIDM-AUTH-SESSION-ID": reply["X-KANIDM-AUTH-SESSION-ID"]})
        # Reauth already selects the mechanism and returns its credential
        # challenge. Sending begin again finalises that session with an error.
        return self._steps(session, payload["state"], password, otp)

    def enroll(self, person, password, mfa):
        """Enrol a primary credential as the person would. Returns (committed, otp, warnings)."""
        _, payload = self.api("GET", f"/v1/person/{person}/_credential/_update_intent")
        _, payload = self.api("POST", "/v1/credential/_exchange_intent", payload["token"])
        session = payload[0]
        update = lambda request: self.api("POST", "/v1/credential/_update", [request, session])[1]
        result = update({"password": password})
        otp = None
        if mfa:
            check = update("totpgenerate")["mfaregstate"]["TotpCheck"]
            otp = {key: check[key] for key in ("secret", "algo", "digits", "step")}
            result = update({"totpverify": [totp(**otp), "household"]})
            if result["mfaregstate"] == "TotpInvalidSha1":
                result = update("totpacceptsha1")
        if not result.get("can_commit"):
            self.api("POST", "/v1/credential/_cancel", session)
            return False, otp, result.get("warnings")
        status, _ = self.api("POST", "/v1/credential/_commit", session)
        return status == 200, otp, result.get("warnings")

    def policy(self, group):
        _, payload = self.api("GET", f"/v1/group/{group}")
        attrs = payload["attrs"]
        return {key: attrs.get(key) for key in ("credential_type_minimum", "allow_primary_cred_fallback")}

    def members(self, group):
        _, payload = self.api("GET", f"/v1/group/{group}")
        return sorted(member.split("@")[0] for member in payload["attrs"].get("member", []))


def jellyfin_headers(token=None):
    # A fresh device per call: Jellyfin ends earlier sessions of the same device.
    value = f'MediaBrowser Client="household-runtime", Device="VM", DeviceId="household-{secrets.token_hex(6)}", Version="1"'
    return {"Authorization": value + (f', Token="{token}"' if token else "")}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--domain", required=True)
    args = parser.parse_args()
    domain = args.domain
    base = ",".join("dc=" + part for part in domain.split("."))

    # Everything below comes from the committed manifests.
    kanidm_config = manifest("identity", "ConfigMap-kanidm-config.yaml")["data"]["server.toml"]
    kanidm_pod = manifest("identity", "Deployment-kanidm.yaml")["spec"]["template"]["spec"]
    kanidm_service = manifest("identity", "Service-kanidm.yaml")["spec"]
    provision_data = manifest("identity", "ConfigMap-kanidm-provision.yaml")["data"]
    provision_job = container(manifest("identity", "Job-kanidm-provision.yaml")["spec"]["template"]["spec"], "provision")
    jellyfin_pod = manifest("jellyfin", "Deployment-jellyfin.yaml")["spec"]["template"]["spec"]
    jellarr_data = manifest("jellyfin-configuration", "ConfigMap-jellarr-configuration.yaml")["data"]
    jellarr_pod = manifest("jellyfin-configuration", "Job-jellyfin-configuration.yaml")["spec"]["template"]["spec"]
    seerr_image = container(manifest("seerr", "StatefulSet-seerr.yaml")["spec"]["template"]["spec"], "main")["image"]
    ldaps = next(port for port in kanidm_service["ports"] if port["name"] == "ldaps")
    listen = tomllib.loads(kanidm_config)["ldapbindaddress"]
    require(listen.endswith(f":{ldaps['port']}"), "Kanidm listens for LDAPS on its Service port", listen)
    jellarr_config = json.loads(jellarr_data["config.yml"])
    ldap_plugin = next(plugin for plugin in jellarr_config["plugins"] if plugin["name"] == "LDAP-Auth")["configuration"]
    require(ldap_plugin["LdapServer"] == domain and ldap_plugin["LdapPort"] == ldaps["port"], "Jellyfin's plugin targets the Kanidm hostname and LDAPS port", ldap_plugin)
    household = provision_data and json.loads(provision_data["policies.json"])
    household_group = next(p["group"] for p in household if p.get("allowPrimaryCredFallback") is True)
    admin_group = next(item["value"] for item in provision_job["env"] if item["name"] == "KANIDM_ADMIN_GROUP")
    administrators = json.loads(provision_data["members.json"])
    require(administrators, "the committed state declares an administrator", administrators)
    owner = administrators[0]

    shutil.rmtree(WORK, ignore_errors=True)
    pki = WORK / "pki"
    pki.mkdir(parents=True)
    os.chmod(WORK, 0o755)
    (pki / "leaf.ext").write_text(
        "basicConstraints = CA:FALSE\nkeyUsage = critical, digitalSignature\n"
        f"extendedKeyUsage = serverAuth\nsubjectAltName = DNS:{domain}\n"
    )
    run("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "2",
        "-subj", "/CN=household-test-ca", "-addext", "basicConstraints=critical,CA:TRUE",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-keyout", str(pki / "ca.key"), "-out", str(pki / "ca.crt"))
    run("openssl", "req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
        "-subj", f"/CN={domain}", "-keyout", str(pki / "tls.key"), "-out", str(pki / "tls.csr"))
    run("openssl", "x509", "-req", "-in", str(pki / "tls.csr"), "-CA", str(pki / "ca.crt"), "-CAkey", str(pki / "ca.key"),
        "-CAcreateserial", "-days", "2", "-extfile", str(pki / "leaf.ext"), "-out", str(pki / "leaf.crt"))
    tls = WORK / "kanidm-tls"
    tls.mkdir()
    (tls / "tls.crt").write_text((pki / "leaf.crt").read_text() + (pki / "ca.crt").read_text())
    shutil.copy(pki / "tls.key", tls / "tls.key")
    (WORK / "kanidm-config").mkdir()
    (WORK / "kanidm-config/server.toml").write_text(kanidm_config)
    (WORK / "kanidm-data").mkdir()
    trust = WORK / "trust"
    trust.mkdir()
    shutil.copy(pki / "ca.crt", trust / "ca.crt")
    for path in ("kanidm-tls", "kanidm-config", "kanidm-data"):
        run("chown", "-R", "1000:1000", str(WORK / path))
    cafile = str(pki / "ca.crt")

    run("docker", "network", "create", "household")
    kanidm_image = container(kanidm_pod, "kanidm")["image"]
    kanidm_run = ["docker", "run", "-d", "--name", "kanidm", "--network", "household", "--network-alias", domain,
                  "--user", "1000:1000", "-p", "127.0.0.1:443:8443", "-p", f"127.0.0.1:{ldaps['port']}:{ldaps['port']}",
                  "-v", f"{WORK}/kanidm-data:/data", "-v", f"{WORK}/kanidm-config/server.toml:/etc/kanidm/server.toml:ro",
                  "-v", f"{tls}:/etc/kanidm/tls:ro", kanidm_image, *container(kanidm_pod, "kanidm")["command"],
                  *container(kanidm_pod, "kanidm")["args"]]
    run(*kanidm_run)
    kanidm = Kanidm(domain, cafile)
    wait(lambda: kanidm.http.call("GET", "/status")[0] == 200, "Kanidm", 300)
    recovered = run("docker", "exec", "kanidm", "/sbin/kanidmd", "scripting", "recover-account", "idm_admin",
                    "-c", "/etc/kanidm/server.toml").stdout
    admin_password = next(json.loads(line)["output"] for line in recovered.splitlines()
                          if line.startswith("{") and json.loads(line).get("status") == "ok")
    secrets_dir = WORK / "credentials"
    secrets_dir.mkdir()
    (secrets_dir / "idm-admin-password").write_text(admin_password)
    run("chown", "-R", "1000:1000", str(secrets_dir))
    kanidm.admin = kanidm.login("idm_admin", admin_password)
    require(kanidm.admin is not None, "idm_admin signs in")

    # The committed provisioning Job, without OAuth2 clients. The fixture's
    # published 443→8443 listener stands in for Kanidm's HTTPS Service.
    desired = WORK / "desired"
    desired.mkdir()
    state = json.loads(provision_data["state.json"])
    # kanidm-provision requires systems.oauth2 even when no clients are declared.
    state["systems"]["oauth2"] = {}
    (desired / "state.json").write_text(json.dumps(state))
    (desired / "clients.json").write_text("[]")
    for name in ("members.json", "policies.json"):
        (desired / name).write_text(provision_data[name])
    run("chmod", "-R", "a+rX", str(desired))

    def provision(label):
        result = run("docker", "run", "--rm", "--network", "host", "--add-host", f"{domain}:127.0.0.1",
                     "--user", "1000:1000", "--read-only",
                     "--tmpfs", "/work:mode=0700,uid=1000,gid=1000", *environment(provision_job),
                     "-e", "SSL_CERT_FILE=/test-trust/ca.crt", "-v", f"{trust}:/test-trust:ro",
                     "-v", f"{desired}:/desired:ro", "-v", f"{secrets_dir}:/credentials:ro",
                     provision_job["image"], check=False)
        require(result.returncode == 0, f"provisioning Job succeeds ({label})", {"exit": result.returncode})

    provision("first run")
    policies = {group: kanidm.policy(group) for group in ("idm_all_persons", admin_group, household_group)}
    evidence("account-policies", policies)
    require(policies[admin_group] == {"credential_type_minimum": ["mfa"], "allow_primary_cred_fallback": ["false"]},
            "administrators: MFA minimum, no primary-password LDAP fallback", policies)
    require(policies[household_group] == {"credential_type_minimum": ["any"], "allow_primary_cred_fallback": ["true"]},
            "household: password-only allowed, primary-password LDAP fallback", policies)
    require(policies["idm_all_persons"]["credential_type_minimum"] == ["any"], "all-persons floor lowered to any", policies)
    require(kanidm.members(admin_group) == sorted(administrators), "declared administrators granted", kanidm.members(admin_group))

    # Operator and user steps from docs/operations/identity.md.
    def person(name, groups):
        status, _ = kanidm.api("POST", "/v1/person", {"attrs": {"name": [name], "displayname": [name.title()]}})
        require(status == 200, f"operator creates {name}", status)
        for group in groups:
            kanidm.api("POST", f"/v1/group/{group}/_attr/member", [name])
        status, _ = kanidm.api("POST", f"/v1/person/{name}/_unix", {"shell": None, "gidnumber": None})
        require(status == 200, f"operator makes {name} a POSIX account", status)

    # Bad-password probes must not softlock the identities used by later
    # success/migration cases. Keep native anti-bruteforce policy unchanged.
    negative_members = ("empty-password", "wrong-password", "posix-password")
    primary = {name: secrets.token_urlsafe(24) for name in (owner, "ana", "hana", "mallory", "admin-password", *negative_members)}
    unix = {name: secrets.token_urlsafe(24) for name in (owner, "ana", "hana", "mallory", "admin-password", "posix-password")}
    person("hana", [household_group])
    person("mallory", [])
    person("ana", [admin_group, household_group])
    person("admin-password", [admin_group])
    for name in negative_members:
        person(name, [household_group])
    kanidm.api("POST", f"/v1/person/{owner}/_unix", {"shell": None, "gidnumber": None})

    committed, _, warnings = kanidm.enroll("ana", primary["ana"], mfa=False)
    require(not committed and "MfaRequired" in (warnings or []), "an administrator cannot enrol a password-only credential", warnings)
    otps = {}
    for name in (owner, "ana", "admin-password"):
        committed, otps[name], warnings = kanidm.enroll(name, primary[name], mfa=True)
        require(committed, f"{name} enrols password and TOTP", warnings)
    for name in ("hana", "mallory", *negative_members):
        committed, _, warnings = kanidm.enroll(name, primary[name], mfa=False)
        require(committed, f"{name} enrols a password-only credential", warnings)
    require(kanidm.login("hana", primary["hana"]) is not None, "a household member signs in to Kanidm with only a password")

    # Each administrator sets their own POSIX password.
    for name in (owner, "ana", "admin-password"):
        session = kanidm.login(name, primary[name], otps[name])
        require(session is not None, f"{name} authenticates with web MFA")
        status, _ = kanidm.api("PUT", f"/v1/person/{name}/_unix/_credential", {"value": unix[name]}, token=session)
        require(status == 403, "a fresh session cannot set a POSIX password", status)
        privileged = kanidm.reauth(session, primary[name], otps[name])
        require(privileged is not None, f"{name} completes native reauthentication")
        status, _ = kanidm.api("PUT", f"/v1/person/{name}/_unix/_credential", {"value": unix[name]}, token=privileged)
        require(status == 200, f"{name} sets a POSIX password after reauthentication", status)
    require(kanidm.login(owner, unix[owner]) is None, "a POSIX password does not sign in to Kanidm")
    require(kanidm.login(owner, primary[owner], otps[owner]) is not None, "the administrator's MFA sign-in still works")
    require(kanidm.login(owner, primary[owner]) is None, "the administrator's web password alone cannot bypass MFA")
    # A nonmember must have a working directory credential: otherwise Kanidm's
    # disabled primary fallback could hide a broken Jellyfin group filter.
    session = kanidm.login("mallory", primary["mallory"])
    require(session is not None, "the outsider authenticates to Kanidm")
    privileged = kanidm.reauth(session, primary["mallory"], None)
    require(privileged is not None, "the outsider completes native reauthentication")
    status, _ = kanidm.api("PUT", "/v1/person/mallory/_unix/_credential", {"value": unix["mallory"]}, token=privileged)
    require(status == 200, "the outsider sets a valid POSIX password", status)

    def bind(name, password):
        result = subprocess.run(["ldapwhoami", "-H", f"ldaps://{domain}:{ldaps['port']}", "-x", "-D", f"name={name}", "-y", "/dev/stdin"],
                                text=True, capture_output=True, input=password, timeout=60,
                                env=dict(os.environ, LDAPTLS_CACERT=cafile))
        authenticated = result.returncode == 0 and f"u: {name}@" in result.stdout
        evidence("ldap-auth", {"name": name, "exit": result.returncode, "identity": result.stdout.strip(), "authenticated": authenticated})
        return authenticated

    require(bind("hana", primary["hana"]), "household member binds with their Kanidm password")
    for name, password, label in (
        ("empty-password", "", "empty"),
        ("wrong-password", "x" + primary["wrong-password"], "wrong"),
    ):
        require(bind(name, primary[name]), f"the {label}-password LDAP case has a valid positive control")
        require(not bind(name, password), f"an {label} password does not bind")
    require(bind("mallory", unix["mallory"]), "the outsider has valid LDAP credentials before application refusal")
    require(bind(owner, unix[owner]), "an administrator binds with their POSIX password")
    require(not bind(owner, primary[owner]), "an administrator's web password does not bind")

    # Jellyfin: provisioner, plugin installer, stock runtime, as the Deployment orders them.
    jf = WORK / "jellyfin"
    for path in ("config", "cache", "media/movies", "media/tv", "provision", "secrets"):
        (jf / path).mkdir(parents=True)
    local_password = secrets.token_urlsafe(24)
    (jf / "secrets/password").write_text(local_password + "\n")
    run("chown", "-R", "751:751", str(jf))
    uid = f"{jellyfin_pod['securityContext']['runAsUser']}:{jellyfin_pod['securityContext']['runAsGroup']}"
    provisioner = container(jellyfin_pod, "provision", init=True)
    plugins = container(jellyfin_pod, "plugins", init=True)
    runtime = container(jellyfin_pod, "jellyfin")

    def jellyfin_init():
        run("docker", "run", "--rm", "--user", uid, *environment(provisioner),
            "-v", f"{jf}/config:/config", "-v", f"{jf}/cache:/cache", "--tmpfs", f"/run/provision:mode=0700,uid=751,gid=751",
            "-v", f"{jf}/secrets/password:/run/secrets/password:ro", "--entrypoint", provisioner["command"][0],
            provisioner["image"], timeout=900)
        result = run("docker", "run", "--rm", "--user", uid, "-v", f"{jf}/config:/config",
            "--entrypoint", plugins["command"][0], plugins["image"], *plugins["command"][1:], *plugins.get("args", []))
        return result.stdout

    jelly = Http("http://127.0.0.1:8096")

    def start_jellyfin():
        run("docker", "run", "-d", "--name", "jellyfin", "--network", "household", "--network-alias", JELLYFIN_HOST,
            "--user", uid, "-p", "127.0.0.1:8096:8096", "-e", "SSL_CERT_FILE=/test-trust/ca.crt",
            "-v", f"{trust}:/test-trust:ro", "-v", f"{jf}/config:/config", "-v", f"{jf}/cache:/cache",
            "-v", f"{jf}/media:/media:ro", runtime["image"])
        def ready():
            status, _, health = jelly.call("GET", "/health")
            # ASP.NET health checks return HTTP 200 for Degraded as well as
            # Healthy. Do not attempt authentication while stock startup runs.
            if status != 200 or health != "Healthy":
                return False
            public_status, _, info = jelly.call("GET", "/System/Info/Public")
            claimed = public_status == 200 and isinstance(info, dict) and info.get("StartupWizardCompleted") is True
            if claimed:
                evidence("jellyfin-readiness", {"health_http": status, "health_body": health, "public_http": public_status, "public_body": info})
            return claimed
        wait(ready, "Jellyfin application startup", 300)

    jellyfin_init()
    start_jellyfin()

    def authenticate(name, password):
        status, _, payload = jelly.call("POST", "/Users/AuthenticateByName", {"Username": name, "Pw": password}, jellyfin_headers())
        if status != 200:
            evidence("jellyfin-auth", {"name": name, "http": status, "authenticated": False})
            return status, None, None
        user = payload["User"]
        summary = {"id": user["Id"], "admin": user["Policy"]["IsAdministrator"],
                   "provider": user["Policy"].get("AuthenticationProviderId")}
        evidence("jellyfin-auth", {"name": name, "http": status, "user": summary})
        return status, payload["AccessToken"], summary

    status, admin_token, local_owner = authenticate(owner, local_password)
    require(status == 200 and local_owner["admin"] and local_owner["provider"] == DEFAULT_PROVIDER,
            "the provisioned local administrator signs in", {"status": status, "user": local_owner})
    admin = jellyfin_headers(admin_token)
    _, _, loaded = jelly.call("GET", "/Plugins", None, admin)
    ldap_loaded = next((p for p in loaded if p["Name"] == "LDAP-Auth"), None)
    require(ldap_loaded is not None and ldap_loaded["Status"] == "Active", "the LDAP plugin loads on the pinned Jellyfin", ldap_loaded)
    meta = json.loads(next((jf / "config/plugins").glob("LDAP Authentication_*/meta.json")).read_text())
    require(meta["autoUpdate"] is False, "Jellyfin will not auto-update the pinned plugin", meta.get("autoUpdate"))

    # The jellyfin-configuration Job: API-key bootstrap, then Jellarr.
    jellarr = WORK / "jellarr"
    for path in ("config", "run"):
        (jellarr / path).mkdir(parents=True)
    (jellarr / "config/config.yml").write_text(jellarr_data["config.yml"])
    (jellarr / "config/bootstrap.mjs").write_text(jellarr_data["bootstrap.mjs"])
    run("chmod", "-R", "a+rX", str(jellarr / "config"))
    run("chown", "751:751", str(jellarr / "run"))
    bootstrap = container(jellarr_pod, "bootstrap", init=True)
    main_container = container(jellarr_pod, "jellarr")

    def configure(label):
        # Every configuration Job gets a new Pod-local emptyDir. The previous
        # Pod's mode-0400 key must not become this Pod's bootstrap output.
        pod_run = jellarr / "run" / secrets.token_hex(6)
        pod_run.mkdir()
        run("chown", "751:751", str(pod_run))
        run("docker", "run", "--rm", "--network", "household", "--user", uid, *environment(bootstrap),
            "-v", f"{jellarr}/config:/config:ro", "-v", f"{jf}/secrets/password:/run/secrets/password:ro",
            "-v", f"{pod_run}:/run/jellarr", "--entrypoint", bootstrap["command"][0], bootstrap["image"], *bootstrap["args"])
        result = run("docker", "run", "--rm", "--network", "household", "--user", uid,
                     "-v", f"{jellarr}/config:/config:ro", "-v", f"{pod_run}:/run/jellarr:ro", main_container["image"])
        lines = [line for line in result.stdout.splitlines() if "plugin" in line]
        evidence(f"jellarr-{label}", lines)
        return lines

    configure("first run")
    configure("second run")
    _, _, applied = jelly.call("GET", f"/Plugins/{ldap_loaded['Id']}/Configuration", None, admin)
    require({k: applied.get(k) for k in ldap_plugin} == ldap_plugin, "the plugin holds the declared configuration")
    _, _, loaded = jelly.call("GET", "/Plugins", None, admin)
    removable = sorted((p["Name"], p["Version"]) for p in loaded if p.get("CanUninstall"))
    require(removable == [("LDAP-Auth", ldap_loaded["Version"])], "Jellarr installed no plugin", removable)

    def users():
        _, _, listed = jelly.call("GET", "/Users", None, admin)
        return {user["Name"]: user["Id"] for user in listed}

    # Sign-in through the directory.
    status, hana_token, hana = authenticate("hana", primary["hana"])
    require(status == 200 and not hana["admin"] and hana["provider"] == LDAP_PROVIDER,
            "a household member signs in to Jellyfin with their Kanidm password", hana)
    require(authenticate("hana", primary["hana"])[2]["id"] == hana["id"], "the next sign-in reaches the same Jellyfin user")
    status, _, ana = authenticate("ana", unix["ana"])
    require(status == 200 and ana["admin"], "an administrator-group member becomes a Jellyfin administrator", ana)
    status, _, strict = authenticate("admin-password", unix["admin-password"])
    require(status == 200 and strict["admin"], "the administrator web-password refusal has a valid POSIX positive control", strict)
    require(authenticate("admin-password", primary["admin-password"])[0] != 200, "an administrator's web password does not sign in to Jellyfin")
    require(authenticate("mallory", unix["mallory"])[0] != 200 and "mallory" not in users(),
            "a person outside both groups is refused and gets no Jellyfin user")
    for name, password, label in (
        ("empty-password", "", "empty"),
        ("wrong-password", "x" + primary["wrong-password"], "wrong"),
    ):
        require(authenticate(name, primary[name])[0] == 200, f"the {label}-password Jellyfin case has a valid positive control")
        require(authenticate(name, password)[0] != 200, f"an {label} password is refused")
    session = kanidm.login("posix-password", primary["posix-password"])
    privileged = kanidm.reauth(session, primary["posix-password"], None)
    require(privileged is not None, "the separate-password negative case completes reauthentication")
    status, _ = kanidm.api("PUT", "/v1/person/posix-password/_unix/_credential", {"value": unix["posix-password"]}, token=privileged)
    require(status == 200, "the separate-password negative case sets a POSIX password", status)
    require(authenticate("posix-password", unix["posix-password"])[0] == 200, "the primary-fallback refusal has a valid POSIX positive control")
    require(authenticate("posix-password", primary["posix-password"])[0] != 200, "a set POSIX password replaces LDAP primary-password fallback")
    require(authenticate(owner, unix[owner])[0] != 200, "the directory credential does not sign in to the local administrator")
    status, _, again = authenticate(owner, local_password)
    require(status == 200 and again["id"] == local_owner["id"] and again["provider"] == DEFAULT_PROVIDER,
            "the local administrator keeps its account and local password", again)

    _, _, linked = jelly.call("GET", f"/Plugins/{ldap_loaded['Id']}/Configuration", None, admin)
    status, _, _ = jelly.call("POST", f"/Plugins/{ldap_loaded['Id']}/Configuration",
                             dict(linked, LdapServer="kanidm"), admin)
    require(status == 204, "the certificate-hostname counterfactual is installed", status)
    require(authenticate("hana", primary["hana"])[0] != 200,
            "Jellyfin refuses LDAPS when the directory certificate has the wrong hostname")
    configure("restore verified directory")
    _, _, reconciled = jelly.call("GET", f"/Plugins/{ldap_loaded['Id']}/Configuration", None, admin)
    require(reconciled["LdapUsers"] == linked["LdapUsers"], "Jellarr preserves plugin-owned directory links")
    status, _, restored = authenticate("hana", primary["hana"])
    require(status == 200 and restored["id"] == hana["id"], "certificate repair restores the same directory user")

    # Provisioning owns administrator membership: the next run removes ana,
    # who stays in the household group. Household membership survives.
    provision("second run")
    require(kanidm.members(household_group) == sorted(["ana", "hana", *negative_members]),
            "provisioning leaves household members alone", kanidm.members(household_group))
    require("ana" not in kanidm.members(admin_group), "provisioning removes the undeclared administrator")
    status, _, ana = authenticate("ana", unix["ana"])
    require(status == 200 and not ana["admin"], "leaving the administrator group removes Jellyfin administration at the next sign-in", ana)
    kanidm.api("DELETE", f"/v1/group/{household_group}/_attr/member", ["hana"])
    require(authenticate("hana", primary["hana"])[0] != 200, "leaving the household group refuses the next sign-in")
    status, _, _ = jelly.call("GET", "/Users/Me", None, jellyfin_headers(hana_token))
    evidence("session-after-leaving-household-group", status)
    kanidm.api("POST", f"/v1/group/{household_group}/_attr/member", ["hana"])
    status, _ = kanidm.api("DELETE", f"/v1/group/{household_group}/_attr/member", ["ana"])
    require(status == 200, "the operator removes a POSIX-backed household member", status)
    require(bind("ana", unix["ana"]), "the removed member still has valid LDAP credentials")
    require(authenticate("ana", unix["ana"])[0] != 200,
            "Jellyfin refuses the removed member independently of LDAP password policy")
    status, _ = kanidm.api("POST", f"/v1/group/{household_group}/_attr/member", ["ana"])
    require(status == 200, "the operator restores the POSIX-backed household member", status)
    status, _, restored_ana = authenticate("ana", unix["ana"])
    require(status == 200 and restored_ana["id"] == ana["id"] and not restored_ana["admin"],
            "restoring membership retains the same nonadministrator account", restored_ana)

    # A Pod restart reinstalls the pinned build and removes another version.
    run("docker", "rm", "-f", "jellyfin")
    stray = jf / "config/plugins/LDAP Authentication_23.0.0.0"
    stray.mkdir()
    (stray / "meta.json").write_text("{}")
    run("chown", "-R", "751:751", str(stray))
    jellyfin_init()
    require(not stray.exists(), "the plugin installer removes another version of the plugin")
    start_jellyfin()
    status, admin_token, _ = authenticate(owner, local_password)
    admin = jellyfin_headers(admin_token)
    status, _, after = authenticate("hana", primary["hana"])
    require(status == 200 and after["id"] == hana["id"], "after a restart the household member reaches the same user", after)

    # Seerr signs people in through Jellyfin.
    seerr_dir = WORK / "seerr"
    seerr_dir.mkdir()
    run("chown", "1000:1000", str(seerr_dir))
    run("docker", "run", "-d", "--name", "seerr", "--network", "household", "-p", "127.0.0.1:5055:5055",
        "-v", f"{seerr_dir}:/app/config", seerr_image)
    seerr_owner = Http("http://127.0.0.1:5055", cookies=True)
    wait(lambda: seerr_owner.call("GET", "/api/v1/settings/public")[0] == 200, "Seerr", 300)
    status, _, claimed = seerr_owner.call("POST", "/api/v1/auth/jellyfin", {
        "username": owner, "password": local_password, "hostname": JELLYFIN_HOST, "port": 8096,
        "useSsl": False, "urlBase": "", "email": "owner@household.invalid", "serverType": 2})
    require(status == 200 and claimed["id"] == 1, "the local administrator claims Seerr", status)

    def seerr_login(name, password):
        session = Http("http://127.0.0.1:5055", cookies=True)
        status, _, _ = session.call("POST", "/api/v1/auth/jellyfin", {"username": name, "password": password})
        me_status, _, me = session.call("GET", "/api/v1/auth/me")
        evidence("seerr-auth", {"name": name, "http": status, "me_http": me_status,
                               "user": {key: (me or {}).get(key) for key in ("id", "jellyfinUsername", "permissions")}})
        return status, me if me_status == 200 else None

    status, seerr_hana = seerr_login("hana", primary["hana"])
    require(status == 200 and seerr_hana["jellyfinUsername"] == "hana", "a household member signs in to Seerr")
    require(seerr_login("mallory", unix["mallory"])[0] != 200, "Seerr refuses an outsider with valid LDAP credentials")
    require(seerr_login(owner, local_password)[0] == 200, "the local administrator still signs in to Seerr")

    # Later MFA adoption changes credentials, not Jellyfin or Seerr identities.
    hana_session = kanidm.login("hana", primary["hana"])
    privileged = kanidm.reauth(hana_session, primary["hana"], None)
    require(privileged is not None, "the household member obtains a privileged session")
    status, _ = kanidm.api("PUT", "/v1/person/hana/_unix/_credential", {"value": unix["hana"]}, token=privileged)
    require(status == 200, "the household member sets a separate POSIX password before MFA adoption", status)
    status, _, separate = authenticate("hana", unix["hana"])
    require(status == 200 and separate["id"] == hana["id"], "the separate password reaches the existing Jellyfin account")
    committed, hana_otp, warnings = kanidm.enroll("hana", primary["hana"], mfa=True)
    require(committed, "the household member enrolls MFA before raising the floor", warnings)
    status, _ = kanidm.api("PUT", "/v1/group/idm_all_persons/_attr/credential_type_minimum", ["mfa"])
    require(status == 200, "the later all-persons MFA minimum is applied", status)
    committed, _, warnings = kanidm.enroll("mallory", primary["mallory"], mfa=False)
    require(not committed, "the new minimum refuses password-only credential enrollment", warnings)
    require(kanidm.login("hana", primary["hana"], hana_otp) is not None, "the household member signs in to Kanidm with MFA")
    require(kanidm.login("hana", primary["hana"]) is None, "the household member's web password alone cannot bypass the later MFA policy")
    require(kanidm.login("hana", unix["hana"]) is None, "the directory password cannot sign in to Kanidm")
    require(bind("hana", unix["hana"]), "LDAP remains available with the separate password after MFA adoption")
    status, _, migrated = authenticate("hana", unix["hana"])
    require(status == 200 and migrated["id"] == hana["id"], "MFA adoption preserves the Jellyfin user ID")
    status, migrated_seerr = seerr_login("hana", unix["hana"])
    require(status == 200 and migrated_seerr["id"] == seerr_hana["id"],
            "MFA adoption preserves the Seerr user ID", {"before": seerr_hana["id"], "after": (migrated_seerr or {}).get("id")})
    require(not bind("hana", primary["hana"]), "the MFA web password cannot bind to LDAP")

    # Kanidm down: the local administrator is the break-glass sign-in.
    require(authenticate("ana", unix["ana"])[0] == 200, "the directory-outage case has an unlocked positive control")
    run("docker", "stop", "kanidm")
    require(authenticate(owner, local_password)[0] == 200, "with Kanidm down the local administrator signs in")
    require(authenticate("ana", unix["ana"])[0] != 200, "with Kanidm down directory sign-in is refused")
    print("HOUSEHOLD_SIGN_IN_OK", flush=True)


if __name__ == "__main__":
    main()
