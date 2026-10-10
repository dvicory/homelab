# Kanidm probe for identity-provision-runtime. It runs inside the VM, talks
# to Kanidm's HTTP API as idm_admin, and prints only non-secret facts:
# Kanidm state, whether a published Secret equals Kanidm's client secret, and
# the groups claim of an ID token. It never prints a credential.
import base64
import hashlib
import hmac
import json
import re
import secrets
import ssl
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://" + sys.argv[1]
KUBECTL = sys.argv[2].split()
CONTEXT = ssl.create_default_context(cafile="/root/pki/ca.crt")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


OPENER = urllib.request.build_opener(urllib.request.HTTPSHandler(context=CONTEXT), NoRedirect)


def call(method, path, body=None, headers=None, form=False, expect=(200,)):
    headers = dict(headers or {})
    data = None
    if body is not None:
        if form:
            data = urllib.parse.urlencode(body).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
    request = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with OPENER.open(request, timeout=30) as response:
            status, reply, payload = response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        status, reply, payload = error.code, error.headers, error.read()
    if status not in expect:
        # Bodies may echo credentials; report only the status and path.
        raise SystemExit(f"{method} {path.split('?')[0]} returned HTTP {status}")
    return reply, payload


def totp(secret, algo, digits, step):
    counter = struct.pack(">Q", int(time.time()) // step)
    digest = hmac.new(bytes(secret), counter, getattr(hashlib, algo)).digest()
    offset = digest[-1] & 0x0F
    code = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return code % (10**digits)


def login(username, password, otp=None):
    reply, payload = call("POST", "/v1/auth", {"step": {"init": username}})
    session = {"X-KANIDM-AUTH-SESSION-ID": reply["X-KANIDM-AUTH-SESSION-ID"]}
    mech = "passwordmfa" if otp else "password"
    assert mech in json.loads(payload)["state"]["choose"], "authentication mechanism unavailable"
    _, payload = call("POST", "/v1/auth", {"step": {"begin": mech}}, session)
    state = json.loads(payload)["state"]
    while "continue" in state:
        if "totp" in state["continue"]:
            credential = {"totp": totp(**otp)}
        elif "password" in state["continue"]:
            credential = {"password": password}
        else:
            raise SystemExit("unexpected authentication challenge")
        _, payload = call("POST", "/v1/auth", {"step": {"cred": credential}}, session)
        state = json.loads(payload)["state"]
    assert "success" in state, "authentication denied"
    return {"Authorization": "Bearer " + state["success"]}


with open("/root/idm-admin-password") as handle:
    ADMIN = login("idm_admin", handle.read().strip())


def get(path):
    return json.loads(call("GET", path, headers=ADMIN)[1])


def short(spn):
    return spn.split("@")[0]


def state(clients):
    group = get("/v1/group/homelab-admin")["attrs"]
    result = {
        "members": sorted(short(member) for member in group.get("member", [])),
        "credential_type_minimum": group.get("credential_type_minimum", []),
        "clients": {},
    }
    for name in clients:
        attrs = get(f"/v1/oauth2/{name}")["attrs"]
        maps = {}
        for entry in attrs.get("oauth2_rs_scope_map", []):
            spn, scopes = entry.split(": ", 1)
            maps[short(spn)] = sorted(re.findall(r'"([^"]+)"', scopes))
        result["clients"][name] = {
            "scope_maps": maps,
            "sup_scope_maps": attrs.get("oauth2_rs_sup_scope_map", []),
            "strict_redirect": attrs.get("oauth2_strict_redirect_uri", []),
            "redirects": sorted(attrs.get("oauth2_rs_origin", [])),
        }
    return result


def basic_secret(client):
    return get(f"/v1/oauth2/{client}/_basic_secret")


def secret_matches(client, namespace, name, key):
    secret = json.loads(
        subprocess.run(
            KUBECTL + ["get", "secret", "--namespace", namespace, name, "--output", "json"],
            check=True,
            capture_output=True,
        ).stdout
    )
    published = base64.b64decode(secret.get("data", {}).get(key, ""))
    return hmac.compare_digest(published, basic_secret(client).encode())


def oidc_groups(person, client, redirect, scopes):
    # Enrol password and TOTP so the person meets homelab-admin's MFA minimum.
    intent = get(f"/v1/person/{person}/_credential/_update_intent")["token"]
    session, _ = json.loads(call("POST", "/v1/credential/_exchange_intent", intent, ADMIN)[1])

    def update(request):
        reply = call("POST", "/v1/credential/_update", [request, session], ADMIN)[1]
        return json.loads(reply)

    password = secrets.token_urlsafe(32)
    update({"password": password})
    check = update("totpgenerate")["mfaregstate"]["TotpCheck"]
    otp = {key: check[key] for key in ("secret", "algo", "digits", "step")}
    status = update({"totpverify": [totp(**otp), "probe"]})
    if status["mfaregstate"] == "TotpInvalidSha1":
        status = update("totpacceptsha1")
    assert status["can_commit"], "credential update cannot commit"
    call("POST", "/v1/credential/_commit", session, ADMIN)
    # Use a fresh TOTP step for sign-in rather than the enrolment code.
    time.sleep(otp["step"] - time.time() % otp["step"] + 1)
    user = login(person, password, otp)

    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=")
    request = {
        "response_type": "code",
        "client_id": client,
        "state": "probe-state",
        "code_challenge": challenge.decode(),
        "code_challenge_method": "S256",
        "redirect_uri": redirect,
        "scope": " ".join(scopes),
        "nonce": "probe-nonce",
    }
    reply, payload = call("POST", "/oauth2/authorise", request, user)
    answer = json.loads(payload)
    if isinstance(answer, dict) and "ConsentRequested" in answer:
        token = answer["ConsentRequested"]["consent_token"]
        reply, _ = call("POST", "/oauth2/authorise/permit", token, user)
    location = reply["Location"]
    assert location.startswith(redirect + "?"), "authorisation redirected elsewhere"
    code = urllib.parse.parse_qs(urllib.parse.urlparse(location).query)["code"][0]
    basic = base64.b64encode(f"{client}:{basic_secret(client)}".encode()).decode()
    _, payload = call(
        "POST",
        "/oauth2/token",
        {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "code_verifier": verifier,
        },
        {"Authorization": "Basic " + basic},
        form=True,
    )
    body = json.loads(payload)["id_token"].split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    return {key: claims.get(key) for key in ("iss", "aud", "groups")}


command, arguments = sys.argv[3], json.loads(sys.argv[4])
if command == "state":
    print(json.dumps(state(**arguments)))
elif command == "secret-matches":
    print(json.dumps(secret_matches(**arguments)))
elif command == "oidc-groups":
    print(json.dumps(oidc_groups(**arguments)))
else:
    raise SystemExit(f"unknown command {command}")
