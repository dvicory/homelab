"""Disposable Kanidm/Envoy authorization scenario; never emit credentials or URLs."""
import json
import ssl
import sys
import traceback
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import Request, urlopen

from playwright.sync_api import sync_playwright

idm, admin, administrator, recovery_file, ca_file, chromium, output_dir = sys.argv[1:]
output = Path(output_dir)
output.mkdir(mode=0o700, parents=True, exist_ok=True)
phase = "bootstrap"
result = {}
trust = ssl.create_default_context(cafile=ca_file)
password = json.loads(Path(recovery_file).read_text())["output"]
Path(recovery_file).unlink()
sensitive = set()
callback_codes = set()
authorization_queries = []


def observe_request(request):
    query = parse_qs(urlsplit(request.url).query)
    if urlsplit(request.url).path.endswith("/oauth2/callback"):
        callback_codes.update(query.get("code", []))
    if urlsplit(request.url).path == "/ui/oauth2" and "client_id" in query:
        authorization_queries.append(query)
    for header in ("authorization", "cookie"):
        value = request.all_headers().get(header)
        if value:
            sensitive.add(value)
            if header == "cookie":
                sensitive.update(part.strip().split("=", 1)[1] for part in value.split(";") if "=" in part)


def api(method, path, data=None, bearer=None, session=None):
    headers = {"Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    if session:
        headers["X-KANIDM-AUTH-SESSION-ID"] = session
    body = None if data is None else json.dumps(data).encode()
    with urlopen(Request(idm + path, body, headers, method=method), context=trust, timeout=20) as response:
        payload = response.read()
        return (json.loads(payload) if payload else None,
                response.headers.get("X-KANIDM-AUTH-SESSION-ID", session))


def credential(page, challenge, create):
    # Chromium creates/signs real WebAuthn messages. Kanidm validates them;
    # neither a credential nor an identity-service response is fabricated here.
    return page.evaluate("""async ({challenge, create}) => {
        const publicKey = create
            ? PublicKeyCredential.parseCreationOptionsFromJSON(challenge.publicKey)
            : PublicKeyCredential.parseRequestOptionsFromJSON(challenge.publicKey);
        const credential = create
            ? await navigator.credentials.create({publicKey})
            : await navigator.credentials.get({publicKey});
        return credential.toJSON();
    }""", {"challenge": challenge, "create": create})


def enroll(page, person, admin_token):
    intent, _ = api("GET", f"/v1/person/{person}/_credential/_update_intent/600", bearer=admin_token)
    update, _ = api("POST", "/v1/credential/_exchange_intent", intent["token"])
    session_token, _ = update
    status, _ = api("POST", "/v1/credential/_update", ["passkeyinit", session_token])
    registration = credential(page, status["mfaregstate"]["Passkey"], True)
    status, _ = api("POST", "/v1/credential/_update", [
        {"passkeyfinish": ["Fixture verified passkey", registration]}, session_token
    ])
    assert status["can_commit"] and not status["warnings"], "native MFA enrollment was not committable"
    api("POST", "/v1/credential/_commit", session_token)


def native_login(page, person):
    state, session = api("POST", "/v1/auth", {"step": {"init": person}})
    assert "passkey" in state["state"]["choose"], "native passkey mechanism absent"
    state, session = api("POST", "/v1/auth", {"step": {"begin": "passkey"}}, session=session)
    challenge = next(item["passkey"] for item in state["state"]["continue"] if "passkey" in item)
    assertion = credential(page, challenge, False)
    state, _ = api("POST", "/v1/auth", {"step": {"cred": {"passkey": assertion}}}, session=session)
    assert isinstance(state["state"].get("success"), str), "native signed passkey authentication denied"
    return state["state"]["success"]


def login_ui(page, person):
    page.locator("#username").fill(person)
    page.locator("form[action='/ui/login/begin'] button[type=submit]").click()
    # This account has only the native passkey. Kanidm's own pkhtml.js invokes
    # navigator.credentials.get on load; the CDP authenticator signs that challenge.


try:
    state, session = api("POST", "/v1/auth", {"step": {"init": "idm_admin"}})
    _, session = api("POST", "/v1/auth", {"step": {"begin": "password"}}, session=session)
    state, _ = api("POST", "/v1/auth", {"step": {"cred": {"password": password}}}, session=session)
    admin_token = state["state"]["success"]
    sensitive.add(admin_token)
    del password
    group, _ = api("GET", "/v1/group/homelab-admin", bearer=admin_token)
    assert group["attrs"]["credential_type_minimum"] == ["mfa"], "deployed MFA policy absent"
    client, _ = api("GET", "/v1/oauth2/household-admin", bearer=admin_token)
    assert client["attrs"]["oauth2_strict_redirect_uri"] == ["true"], "strict redirect policy absent"
    api("POST", "/v1/person", {"attrs": {
        "name": ["fixture-nonmember"], "displayname": ["Fixture nonmember"]
    }}, bearer=admin_token)
    members, _ = api("GET", "/v1/group/homelab-admin/_attr/member", bearer=admin_token)
    assert not any("fixture-nonmember" in member for member in members), "nonmember received a grant"

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=chromium, headless=True)
        try:
            for person, permitted in ((administrator, True), ("fixture-nonmember", False)):
                phase = "administrator" if permitted else "authenticated-nonmember"
                context = browser.new_context()
                context.on("request", observe_request)
                context.set_default_timeout(30000)
                page = context.new_page()
                cdp = context.new_cdp_session(page)
                cdp.send("WebAuthn.enable", {"enableUI": False})
                cdp.send("WebAuthn.addVirtualAuthenticator", {"options": {
                    "protocol": "ctap2", "transport": "internal",
                    "hasResidentKey": True, "hasUserVerification": True,
                    "isUserVerified": True, "automaticPresenceSimulation": True,
                }})
                try:
                    page.goto(idm + "/ui/login")
                    enroll(page, person, admin_token)
                    token = native_login(page, person)
                    # A token validated by the real identity service proves both
                    # actors can authenticate, independently of the OIDC decision.
                    identity, _ = api("GET", "/v1/self", bearer=token)
                    assert identity["youare"]["attrs"]["name"] == [person], "native passkey authenticated the wrong actor"
                    sensitive.add(token)
                    authorization_queries.clear()
                    response = page.goto(admin + "/index.html")
                    assert urlsplit(page.url).hostname == urlsplit(idm).hostname, "unauthenticated origin was not gated"
                    query = authorization_queries[-1]
                    assert query["client_id"] == ["household-admin"] and "homelab_admin" in query["scope"][0].split(), "wrong native OIDC client or grant requested"
                    assert query.get("code_challenge_method") == ["S256"] and query.get("code_challenge"), "native PKCE challenge absent"
                    if not permitted:
                        try:
                            api("GET", "/oauth2/authorise?" + urlencode(query, doseq=True), bearer=token)
                        except HTTPError as denial:
                            assert denial.code == 403, "authenticated nonmember failed for a reason other than native scope denial"
                        else:
                            raise AssertionError("native identity service granted nonmember OAuth scopes")
                    del token
                    login_ui(page, person)
                    if permitted:
                        page.wait_for_selector("form[action='/ui/oauth2/consent'] button[type=submit]")
                        page.locator("form[action='/ui/oauth2/consent'] button[type=submit]").click()
                        page.wait_for_url(admin + "/index.html")
                        response = page.reload()
                        assert response.status == 200 and page.locator("body").inner_text().strip() == "origin", "administrator did not reach origin"
                        page.locator("body").screenshot(path=str(output / "administrator.png"))
                        result["administrator"] = {"native_passkey_authenticated": True, "origin_status": 200}
                        cookies = context.cookies(admin)
                        assert any(cookie["name"].startswith("OauthHMAC") for cookie in cookies), "real Envoy session cookie absent"
                        tampered = browser.new_context()
                        try:
                            tampered.add_cookies([{**cookie, "value": "cookie-secret"} for cookie in cookies])
                            rejected = tampered.new_page()
                            with rejected.expect_response(lambda r: r.url == admin + "/index.html" and r.status == 302):
                                rejected.goto(admin + "/index.html")
                            assert urlsplit(rejected.url).hostname == urlsplit(idm).hostname, "tampered signed session reached origin"
                            result["tampered_session_denied"] = True
                        finally:
                            tampered.close()
                    else:
                        page.wait_for_url("**/ui/oauth2/resume")
                        assert urlsplit(page.url).hostname == urlsplit(idm).hostname, "nonmember reached application origin"
                        page.locator("h2").first.screenshot(path=str(output / "nonmember-denied.png"))
                        with page.expect_response(lambda r: r.url == admin + "/index.html" and r.status == 302):
                            page.goto(admin + "/index.html")
                        result["nonmember"] = {"native_passkey_authenticated": True, "native_scope_denial_status": 403, "origin_redirect_status": 302}
                finally:
                    context.close()
        finally:
            browser.close()
    assert callback_codes, "administrator did not traverse the real authorization-code callback"
    sensitive.update(callback_codes)
    (output / "sensitive.json").write_text(json.dumps(sorted(sensitive)) + "\n")
    phase = "complete"
    (output / "result.json").write_text(json.dumps(result, sort_keys=True) + "\n")
    print("Real Kanidm passkey/OIDC administrator allow and authenticated nonmember denial passed")
except Exception as error:
    # Exception messages may contain callback URLs, bodies or cookies. Report
    # only the exception class, HTTP status and fixture source locations.
    reason = error.reason if isinstance(error, URLError) else None
    failure = {
        "failed_boundary": phase,
        "error_type": type(error).__name__,
        "http_status": error.code if isinstance(error, HTTPError) else None,
        "reason_type": type(reason).__name__ if reason is not None else None,
        "ssl_verify_code": getattr(reason, "verify_code", None),
        "fixture_lines": [frame.lineno for frame in traceback.extract_tb(error.__traceback__)
                          if frame.filename == __file__],
    }
    (output / "result.json").write_text(json.dumps(failure) + "\n")
    raise SystemExit(f"Kanidm authorization fixture failed in {phase}") from None
