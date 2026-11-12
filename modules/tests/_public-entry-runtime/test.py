"""Native NixOS driver: real transport roles, rendered Gateway, K3s and Kanidm."""
import base64
import json
import re
import shlex
import uuid
import time
from pathlib import Path

q = shlex.quote
k = settings["kubectl"]
public = settings["publicIngress"]
idm, admin, private = (settings[key] for key in ("idmHost", "adminHost", "grafanaHost"))
ca = "/root/fixture/ca.crt"


def command(machine, text):
    return machine.succeed(text).strip()


def put(machine, path, value):
    data = base64.b64encode(value.encode()).decode()
    machine.succeed(f"printf %s {q(data)} | base64 -d > {q(path)}")


def objects(key):
    return json.loads(Path(settings[key]).read_text())["items"]


def apply_items(items):
    put(origin, "/root/apply.json", json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
    origin.succeed(f"{k} apply -f /root/apply.json")


def apply(key):
    origin.succeed(f"{k} apply -f {q(settings[key])}")


def get(resource, name, namespace="gateway"):
    return json.loads(command(origin, f"{k} get {resource} {q(name)} -n {q(namespace)} -o json"))


def wait_condition(resource, name, condition="Accepted", namespace="gateway", parent=None):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        item = get(resource, name, namespace)
        status = item.get("status", {})
        if parent is None:
            statuses = [status]
        else:
            statuses = [s for s in status.get("parents", status.get("ancestors", []))
                        if s.get("parentRef", s.get("ancestorRef", {})).get("name") == parent]
        if any(c.get("type") == condition and c.get("status") == "True"
               and c.get("observedGeneration") == item["metadata"]["generation"]
               for s in statuses for c in s.get("conditions", [])):
            return
        time.sleep(1)
    raise AssertionError(f"No current-generation {condition}: {resource}/{name}")


def rollout(name, namespace="gateway"):
    origin.wait_until_succeeds(f"{k} rollout status deployment/{name} -n {namespace} --timeout=10s", timeout=600)


def request(host="origin.test", path="/index.html", direct=False, extra="", machine=None, timeout=15):
    machine = client if machine is None else machine
    address = settings["nodeAddress"] if direct else settings["relayAddress"]
    port = settings["nodePort"] if direct else 443
    return command(machine, f"curl -sS --connect-timeout 3 --max-time {timeout} --cacert {ca} "
                   f"--resolve {q(f'{host}:{port}:{address}')} {extra} {q(f'https://{host}:{port}{path}')}")


def expect_status(expected, **kwargs):
    status = request(extra=kwargs.pop("extra", "") + " -o /root/response -w '%{http_code}'", **kwargs)
    assert int(status) == expected, (kwargs.get("host"), expected, status)


def converge_status(expected, **kwargs):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            expect_status(expected, **kwargs)
            return
        except Exception as error:
            last_error = error
        time.sleep(1)
    raise AssertionError(f"HTTP status did not converge to {expected}") from last_error


def proxy_request(host="origin.test", path="/index.html", metadata="valid"):
    port = public["nodePort"]
    return json.loads(command(relay, f"python3 {q(settings['transportProbe'])} request "
        f"--target {public['originAddress']} --port {port} --host {q(host)} --path {q(path)} "
        f"--ca {ca} --metadata {metadata} --reported-client {settings['privateClientAddress']}"))


def logs(gateway):
    return command(origin, f"{k} logs -n gateway -c envoy --tail=-1 "
                   f"-l gateway.envoyproxy.io/owning-gateway-name={gateway}")


def save_logs():
    for gateway in ("household", "household-public"):
        origin.succeed(f"{k} logs -n gateway -c envoy --tail=-1 "
                       f"-l gateway.envoyproxy.io/owning-gateway-name={gateway} >> /root/{gateway}.log")


def entry(gateway, path, request_id):
    for _ in range(30):
        matches = []
        for line in logs(gateway).splitlines():
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("path") == path and record.get("request_id") == request_id:
                matches.append(record)
        if matches:
            return matches[-1]
        time.sleep(1)
    raise AssertionError("Generated backend ID had no corresponding queryless Gateway access record")


def transfer(source, destination, path, target):
    # /tmp/shared is the driver's VM-to-VM exchange, not command stdout or $out.
    # Remove the owned exchange immediately, including when a copy fails.
    exchange = "/tmp/shared/public-entry-" + uuid.uuid4().hex
    source.succeed(f"mkdir -m 0700 {exchange} && cp {q(path)} {exchange}/data")
    try:
        destination.succeed(f"cp {exchange}/data {q(target)} && chmod 0600 {q(target)}")
    finally:
        source.succeed(f"rm -rf {exchange}")

def browser(endpoint, label, recovery):
    client.succeed("systemctl stop browser-entry.service || true")
    client.succeed(f"systemd-run --collect --unit=browser-entry socat TCP-LISTEN:443,bind=127.0.0.1,reuseaddr,fork TCP:{endpoint}")
    client.wait_for_open_port(443)
    # Both calls run the same native passkey/OIDC helper. Give its fresh
    # nonmember a distinct fixture identity without weakening its assertions.
    helper = settings["authorization"]
    exit_code, _ = client.execute(f"{q(settings['python'])} {q(helper)} https://{idm} https://{admin} "
        f"{q(settings['administrator'])} {q(recovery)} {ca} {q(settings['chromium'])} /root/auth-{label} "
        f"--nonmember fixture-{label}-nonmember", timeout=300)
    result = json.loads(command(client, f"cat /root/auth-{label}/result.json"))
    assert exit_code == 0, {key: result.get(key) for key in ("http_status", "fixture_lines")}
    assert result["administrator"]["native_passkey_authenticated"]
    assert result["administrator"]["origin_status"] == 200
    assert result["nonmember"]["native_passkey_authenticated"]
    assert result["nonmember"]["native_scope_denial_status"] == 403
    assert result["tampered_session_denied"]


start_all()
control.wait_for_unit("headscale.service")
control.wait_for_open_port(443)
for machine, role, expected in ((origin, "origin", public["originAddress"]),
                                 (relay, "relay", public["peerAddress"])):
    control.succeed(f"fixture-enrollment {role}")
    machine.wait_for_unit("multi-user.target")
    machine.succeed("install -d -m 0700 /srv/secrets")
    transfer(control, machine, f"/run/fixture-tailnet/{role}.key", "/srv/secrets/tailscale-auth-key")
    machine.succeed("chmod 0400 /srv/secrets/tailscale-auth-key; systemctl start tailscaled-autoconnect.service")
    machine.wait_until_succeeds(f"test \"$(tailscale ip -4)\" = {expected}", timeout=90)
    machine.succeed("test -c /dev/net/tun && ip -d link show tailscale0 | grep -q tun")
    expected_v6 = "fd7a:115c:a1e0::1" if role == "origin" else public["peerIPv6Address"]
    assert command(machine, "tailscale ip -6") == expected_v6
    assert json.loads(command(machine, "tailscale status --json"))["Self"]["Tags"] == [f"tag:public-{role}"]
    machine.succeed("systemctl start tailscaled-set.service")
relay.succeed("systemctl start haproxy.service")
relay.wait_for_unit("haproxy.service")
origin.wait_for_unit("sshd.service")
# Incus's actual HTTPS listener is enabled only for this disposable VM.
origin.wait_for_unit("incus.service")
origin.succeed("incus admin init --minimal")
origin.succeed("incus config set core.https_address '[::]:8443'")
origin.wait_for_open_port(8443)
origin_v6 = "fd7a:115c:a1e0::1"
for port in (22, 8443):
    origin.succeed(f"nc -6 -z -w2 {origin_v6} {port}")
origin.wait_until_succeeds(f"{k} get --raw=/readyz", timeout=300)
origin.succeed("mkdir -p /root/fixture && chmod 0700 /root/fixture")
client.succeed("mkdir -p /root/fixture /root/.pki/nssdb /root/.local/share/pki/nssdb")
relay.succeed("mkdir -p /root/fixture")

# Model a compromised relay, not an accidentally protective client ACL. The
# origin's unchanged production table is the boundary under test below.
relay.succeed("nft delete table inet public-transport")
origin.succeed("nft add table inet fixture-source; "
    "nft 'add chain inet fixture-source postrouting { type filter hook postrouting priority 101; policy accept; }'; "
    f"nft add rule inet fixture-source postrouting ip saddr {public['peerAddress']} "
    f"ct original ip daddr {public['originAddress']} ct original proto-dst {public['nodePort']} counter")
# Keep a hostile authenticated peer probing throughout resource startup, not
# just after a Ready condition. A successful TCP handshake is a violation.
forbidden = [(address, port) for address in (public["originAddress"], settings["underlayAddress"])
             for port in (settings["nodePort"], 6443, 22, 8443)]
forbidden += [(origin_v6, port) for port in (22, 8443)]
put(relay, "/root/targets.json", json.dumps(forbidden))
relay.succeed(f"systemd-run --unit=containment-monitor python3 {q(settings['transportProbe'])} monitor "
              "--targets /root/targets.json --output /root/containment.json --stop /root/stop-monitor")

# Use the production userspace/nftables enforcer, never K3s's embedded
# kube-router controller. Keep existing namespace mounts when making this
# owned VM's netns directory propagation-capable.
origin.succeed("mkdir -p /var/run/netns && mount --rbind /var/run/netns /var/run/netns && mount --make-rshared /var/run/netns")
apply("networkPolicy")
origin.wait_until_succeeds(f"{k} rollout status daemonset/kube-network-policies -n kube-system --timeout=10s", timeout=300)
origin.wait_until_succeeds(f"{k} get daemonset/kube-network-policies -n kube-system -o json | "
    "jq -e '.status.desiredNumberScheduled > 0 and .status.numberReady == .status.desiredNumberScheduled "
    "and .status.observedGeneration == .metadata.generation'", timeout=300)
apply("retained")
origin.succeed(f"{k} apply --server-side -f {q(settings['crds'])}")
for crd in ("gateways.gateway.networking.k8s.io", "envoyproxies.gateway.envoyproxy.io",
            "clienttrafficpolicies.gateway.envoyproxy.io", "securitypolicies.gateway.envoyproxy.io",
            "backendtlspolicies.gateway.networking.k8s.io"):
    origin.succeed(f"{k} wait crd/{crd} --for=condition=Established --timeout=180s")
apply("controller")
origin.succeed(f"{k} wait job/envoy-gateway-gateway-helm-certgen -n gateway --for=condition=Complete --timeout=300s")
rollout("envoy-gateway")

# Install rendered admission before backend startup. Then exercise that policy
# continuously while actual backend and Envoy pod identities are replaced.
origin_objects = objects("origins")
apply_items([item for item in origin_objects if item["kind"] == "Namespace"])
policies = [item for key in ("publicInitial", "adminRoutes") for item in objects(key)
            if item["kind"] == "NetworkPolicy"]
apply_items(policies)
apply_items([item for item in origin_objects if item["kind"] != "Namespace"])

origin.succeed("openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=fixture-ca "
    "-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign "
    "-keyout /root/fixture/ca.key -out /root/fixture/ca.crt >/dev/null 2>&1")
for name, common, names in (("idm", idm, [idm]), ("gateway", "origin.test", ["origin.test", admin, private])):
    origin.succeed(f"openssl req -new -newkey rsa:2048 -nodes -subj /CN={common} "
        f"-keyout /root/fixture/{name}.key -out /root/fixture/{name}.csr >/dev/null 2>&1")
    put(origin, f"/root/fixture/{name}.ext", "subjectAltName=" + ",".join("DNS:" + host for host in names) + "\nextendedKeyUsage=serverAuth\n")
    origin.succeed(f"openssl x509 -req -in /root/fixture/{name}.csr -CA {ca} -CAkey /root/fixture/ca.key "
        f"-CAcreateserial -days 2 -extfile /root/fixture/{name}.ext -out /root/fixture/{name}.crt >/dev/null 2>&1")
origin.succeed("chmod 0644 /root/fixture/idm.key")
origin.succeed(f"{k} create configmap fixture-ca -n gateway --from-file=ca-certificates.crt={ca}")
origin.succeed(f"{k} create configmap fixture-ca -n identity --from-file=ca.crt={ca}")
for name, namespace, prefix in (("gateway-tls", "gateway", "gateway"), ("kanidm-tls", "identity", "idm")):
    origin.succeed(f"{k} create secret tls {name} -n {namespace} --cert=/root/fixture/{prefix}.crt --key=/root/fixture/{prefix}.key")
for machine in (client, relay):
    transfer(origin, machine, ca, ca)
put(client, "/root/no-targets.json", "[]")
client.succeed(f"systemd-run --unit=public-host-monitor python3 {q(settings['transportProbe'])} monitor "
    f"--targets /root/no-targets.json --output /root/public-host.json --stop /root/stop-public-host "
    f"--target {settings['relayAddress']} --port 443 --host {q(private)} --ca {ca}")
client.succeed(f"systemd-run --unit=public-admin-monitor python3 {q(settings['transportProbe'])} monitor "
    f"--targets /root/no-targets.json --output /root/public-admin.json --stop /root/stop-public-admin "
    f"--target {settings['relayAddress']} --port 443 --host {q(admin)} --ca {ca} --allow-redirect")
for database in ("/root/.pki/nssdb", "/root/.local/share/pki/nssdb"):
    client.succeed(f"certutil -N -d sql:{database} --empty-password && certutil -A -d sql:{database} -n fixture-ca -t 'C,,' -i {ca}")
apply("identity")
rollout("kanidm", "identity")
apply("publicInitial")
for gateway in ("household", "household-public"):
    wait_condition("gateway", gateway)
    wait_condition("gateway", gateway, "Programmed")
    origin.wait_until_succeeds(f"{k} rollout status deployment -n gateway "
        f"-l gateway.envoyproxy.io/owning-gateway-name={gateway} --timeout=10s", timeout=300)
for namespace in ("origin", "gateway-admin-origin", "monitoring"):
    rollout("origin", namespace)
converge_status(200)
converge_status(200, direct=True)
converge_status(200, host=idm, path="/status", direct=True)
expect_status(404, host=admin)
expect_status(404, host=idm, path="/status")

# Actual Service and pod addresses are also forbidden to the authenticated peer.
backend_definition = next(item for item in origin_objects
                          if item["kind"] == "Service" and item["metadata"]["namespace"] == "monitoring")
backend = get("service", backend_definition["metadata"]["name"], "monitoring")
backend_service = backend["spec"]["clusterIP"]
backend_port = backend["spec"]["ports"][0]["port"]
backend_selector = ",".join(f"{name}={value}" for name, value in backend["spec"]["selector"].items())
backend_pod = json.loads(command(origin, f"{k} get pod -n monitoring -l {q(backend_selector)} -o json"))["items"]
backend_ip = backend_pod[0]["status"]["podIP"]
assert command(origin, f"curl -fsS http://{backend_service}:{backend_port}/index.html") == "origin"
assert command(origin, f"curl -fsS http://{backend_ip}:8080/index.html") == "origin"
for port in (settings["nodePort"], 22, 6443, 8443):
    client.succeed(f"nc -z -w 3 {settings['nodeAddress']} {port}")
# A hostile authenticated relay accepts real advertised routes. Headscale ACLs
# intentionally allow these; the guest must reject them before K3s/backend.
origin.succeed("tailscale set --advertise-routes=10.42.0.0/16,10.43.0.0/16")
control.succeed("headscale nodes approve-routes --identifier 1 --routes 10.42.0.0/16,10.43.0.0/16 > /run/fixture-route-approval")
relay.succeed("tailscale set --accept-routes=true")
relay.wait_until_succeeds("ip route show table 52 | grep -q '10.43.0.0/16.*tailscale0'", timeout=60)
forbidden += [(backend_service, backend_port), (backend_ip, 8080)]
put(relay, "/root/targets.next", json.dumps(forbidden))
relay.succeed("mv /root/targets.next /root/targets.json")

with subtest("ordinary private TLS rejects transport preambles; public receiver requires valid PROXY metadata"):
    for metadata in ("missing", "malformed"):
        assert "rejected" in proxy_request(metadata=metadata)
    # Ordinary TLS works at the private receiver; PROXY must fail during TLS,
    # not merely because the peer's network containment happens to reject it.
    result = json.loads(command(client, f"python3 {q(settings['transportProbe'])} request "
        f"--target {settings['nodeAddress']} --port {settings['nodePort']} --ca {ca}"))
    assert result.get("rejected") == "tls", result
    result = proxy_request(path="/headers")
    assert result["status"] == 200
    echoed = {name.lower(): value for name, value in json.loads(result["body"])["headers"].items()}
    assert echoed["x-forwarded-for"] == settings["privateClientAddress"]
    assert echoed["x-request-id"] != "forged-transport-id"
    record = entry("household-public", "/headers", echoed["x-request-id"])
    assert record["client"] == settings["privateClientAddress"]
    # Observe after kube-proxy's srcnat priority, not before a possible SNAT.
    source_rules = json.loads(command(origin, "nft -j list chain inet fixture-source postrouting"))
    counters = [statement["counter"]["packets"]
                for item in source_rules["nftables"] if "rule" in item
                for statement in item["rule"]["expr"] if "counter" in statement]
    assert counters and sum(counters) > 0, "relay source was lost after NodePort source NAT"
    # A forged LAN/administrator address still does not provide authorization.
    assert proxy_request(host=admin)["status"] == 404
    client.succeed(f"if curl -sS --max-time 4 --cacert {ca} --resolve origin.test:{public['nodePort']}:{settings['nodeAddress']} "
        f"https://origin.test:{public['nodePort']}/ -o /root/denied -w '%{{http_code}}' > /root/denied-code; "
        "then exit 1; else test \"$(cat /root/denied-code)\" = 000; fi")

# Bootstrap uses the existing real provisioning resources. Recovery is retained
# only in disposable VM files and consumed by the browser helper, never printed.
origin.succeed(f"umask 077; {k} exec deployment/kanidm -n identity -- /sbin/kanidmd scripting "
    "recover-account idm_admin -c /etc/kanidm/server.toml > /root/fixture/recovery.json 2>/root/fixture/recovery.log")
origin.succeed("jq -er 'select(.status == \"ok\") | .output' /root/fixture/recovery.json > /root/fixture/idm-admin-password")
origin.succeed(f"{k} create secret generic kanidm-provision -n identity --from-file=idm-admin-password=/root/fixture/idm-admin-password")
apply("identityDNS")
origin.succeed(f"{k} rollout restart deployment/coredns -n kube-system")
rollout("coredns", "kube-system")
patch = {"spec": {"template": {"spec": {"volumes": [{"name": "fixture-ca", "configMap": {"name": "fixture-ca"}}],
    "containers": [{"name": "envoy-gateway", "env": [{"name": "SSL_CERT_FILE", "value": "/fixture-ca/ca-certificates.crt"}],
                    "volumeMounts": [{"name": "fixture-ca", "mountPath": "/fixture-ca", "readOnly": True}]}]}}}}
origin.succeed(f"{k} patch deployment envoy-gateway -n gateway --type=strategic -p {q(json.dumps(patch))}")
rollout("envoy-gateway")
apply("provision")
origin.succeed(f"{k} wait job/kanidm-provision -n identity --for=condition=Complete --timeout=600s")
# Before normal publication both actual entries still omit the admin route.
expect_status(404, host=admin)
expect_status(404, host=admin, direct=True)
apply("identityNormalIngress")
apply("public")
apply("adminPolicies")
apply("adminRoutes")
wait_condition("securitypolicy", "argocd-admin", parent="household")
for name in ("argocd", "grafana"):
    wait_condition("httproute", name, parent="household")
wait_condition("httproute", "argocd", parent="household-public")
converge_status(302, host=admin)
converge_status(302, host=private, direct=True)
converge_status(200, host=idm, path="/status")

with subtest("public/private host, TLS name, HTTP authority and spoofed identity isolation"):
    expect_status(404, host=private)
    expect_status(404, extra=f"-H 'Host: {private}'")
    expect_status(200, extra=f"-H 'X-Forwarded-Host: {private}' -H 'Forwarded: host={private}'")
    for name in ("unknown.test", "wrong-name.test"):
        client.fail(f"curl -sSf --connect-timeout 3 --max-time 5 --cacert {ca} --resolve {name}:443:{settings['relayAddress']} https://{name}/")
    for spoof in ("-H 'X-Forwarded-User: forged-admin' -H 'X-Auth-Request-User: forged-admin'",
                  "-H 'Authorization: Bearer bearer-secret'", "-H 'Cookie: OauthHMAC=cookie-secret'"):
        expect_status(302, host=admin, path="/index.html?token=query-secret", extra=spoof)
    assert proxy_request(host=admin)["status"] == 302

with subtest("Gateway sanitizes HTTP metadata, regenerates IDs and correlates queryless logs"):
    request_ids = set()
    for direct in (False, True):
        for supplied in ("12345678-1234-1234-1234-123456789abc", 'malformed-request-id', None):
            path = "/headers"
            headers = ["X-Forwarded-For: 198.51.100.9", "X-Forwarded-Host: forged.test", "X-Forwarded-Proto: http",
                       "X-Forwarded-Port: 81", "Forwarded: for=198.51.100.9", "X-Forwarded-User: forged-admin",
                       "X-Auth-Request-User: forged-admin", "X-Forwarded-Email: forged@example.test",
                       "X-Auth-Request-Email: forged@example.test", "Remote-User: forged-admin",
                       "Authorization: Bearer bearer-secret", "Cookie: session=cookie-secret"]
            if supplied is not None:
                headers.append("X-Request-ID: " + supplied)
            response = json.loads(request(path=path + "?token=query-secret&code=callback-secret", direct=direct,
                                          extra=" ".join("-H " + q(header) for header in headers)))
            actual = {name.lower(): value for name, value in response["headers"].items()}
            request_id = actual["x-request-id"]
            assert re.fullmatch(r"[0-9a-f-]{32,36}", request_id), request_id
            assert request_id != supplied and request_id not in request_ids
            request_ids.add(request_id)
            for name in ("forwarded", "x-forwarded-user", "x-auth-request-user", "x-forwarded-email",
                         "x-auth-request-email", "remote-user", "x-forwarded-host", "x-forwarded-port"):
                assert name not in actual, (name, actual.get(name))
            expected_client = settings["privateClientAddress"] if direct else settings["clientAddress"]
            assert actual.get("x-forwarded-for") == expected_client, actual
            assert actual.get("x-forwarded-proto") == "https"
            assert actual["authorization"] == "Bearer bearer-secret" and actual["cookie"] == "session=cookie-secret"
            assert response["path"].endswith("?token=query-secret&code=callback-secret")
            record = entry("household" if direct else "household-public", path, request_id)
            assert record["client"] == expected_client and record["status"] == 200, record

with subtest("streaming route survives beyond the ordinary 15-second Gateway timeout"):
    started = time.monotonic()
    assert request(path="/slow", timeout=30) == "origin"
    assert time.monotonic() - started >= 17, "streaming request ended before the delayed backend responded"

with subtest("backend TLS name and chain are verified on the real public path"):
    origin.succeed(f"{k} patch backendtlspolicy idm -n identity --type=merge -p "
                   + q(json.dumps({"spec": {"validation": {"hostname": "wrong.test"}}})))
    converge_status(503, host=idm, path="/status")
    apply("public")
    converge_status(200, host=idm, path="/status")
    origin.succeed("openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=untrusted-ca "
        "-keyout /root/fixture/wrong-ca.key -out /root/fixture/wrong-ca.crt >/dev/null 2>&1")
    origin.succeed("openssl x509 -req -in /root/fixture/idm.csr -CA /root/fixture/wrong-ca.crt "
        "-CAkey /root/fixture/wrong-ca.key -CAcreateserial -days 2 -extfile /root/fixture/idm.ext "
        "-out /root/fixture/untrusted.crt >/dev/null 2>&1")
    origin.succeed(f"{k} create secret tls fixture-untrusted -n identity --cert=/root/fixture/untrusted.crt --key=/root/fixture/idm.key")
    for secret, expected in (("fixture-untrusted", 503), ("kanidm-tls", 200)):
        patch = {"spec": {"template": {"spec": {"volumes": [{"name": "tls", "secret": {"secretName": secret}}]}}}}
        origin.succeed(f"{k} patch deployment kanidm -n identity --type=strategic -p {q(json.dumps(patch))}")
        rollout("kanidm", "identity")
        converge_status(expected, host=idm, path="/status")
    origin.succeed(f"{k} delete secret fixture-untrusted -n identity")

with subtest("real native passkey and OIDC administrator/nonmember authorization through relay"):
    transfer(origin, client, "/root/fixture/recovery.json", "/root/recovery-public.json")
    browser(f"{settings['relayAddress']}:443", "public", "/root/recovery-public.json")
    save_logs()

# Public proxy labels must not confer private-backend access, including while
# the backend is being replaced. This is a client pod, not a fake Gateway.
probe = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "public-admission-probe", "namespace": "gateway",
    "labels": {"gateway.envoyproxy.io/owning-gateway-name": "household-public",
               "gateway.envoyproxy.io/owning-gateway-namespace": "gateway"}},
    "spec": {"containers": [{"name": "probe", "image": settings["toolsImage"], "imagePullPolicy": "Never",
        "command": ["/bin/python3", "/probe/transport.py", "monitor", "--targets", "/probe/targets.json",
                    "--output", "/result/report.json", "--stop", "/result/stop"],
        "volumeMounts": [{"name": "probe", "mountPath": "/probe"}, {"name": "result", "mountPath": "/result"}]}],
        "volumes": [{"name": "probe", "configMap": {"name": "public-admission-probe"}}, {"name": "result", "emptyDir": {}}]}}
put(origin, "/root/probe-targets.json", json.dumps([(backend_service, backend_port)]))
origin.succeed(f"{k} create configmap public-admission-probe -n gateway --from-file=transport.py={settings['transportProbe']} "
               "--from-file=targets.json=/root/probe-targets.json")
apply_items([probe])
origin.succeed(f"{k} wait pod/public-admission-probe -n gateway --for=condition=Ready --timeout=180s")
public_backend = get("service", "origin", "origin")["spec"]["clusterIP"]
origin.wait_until_succeeds(f"{k} exec public-admission-probe -n gateway -- "
    f"curl -fsS --max-time 3 http://{public_backend}:8080/index.html | grep -qx origin", timeout=60)
with subtest("replacement and unrelated-workload loss never open private/backend/management paths"):
    for gateway in ("household-public", "household"):
        origin.succeed(f"{k} delete pod -n gateway -l gateway.envoyproxy.io/owning-gateway-name={gateway} "
                       "--field-selector=metadata.name!=public-admission-probe --wait=false")
        if gateway == "household-public":
            expect_status(200, direct=True)
        origin.wait_until_succeeds(f"{k} rollout status deployment -n gateway "
            f"-l gateway.envoyproxy.io/owning-gateway-name={gateway} --timeout=10s", timeout=300)
        converge_status(200)
        converge_status(200, direct=True)
        expect_status(404, host=private)
    origin.succeed(f"{k} rollout restart deployment/origin -n monitoring")
    rollout("origin", "monitoring")
    origin.succeed(f"{k} scale deployment/origin -n monitoring --replicas=0")
    converge_status(200)
    converge_status(200, host=idm, path="/status")
    origin.succeed(f"{k} scale deployment/origin -n monitoring --replicas=1")
    rollout("origin", "monitoring")
    time.sleep(3)
    monitor = json.loads(command(origin, f"{k} exec public-admission-probe -n gateway -- cat /result/report.json"))
    assert not monitor["violations"] and all(count >= 5 for count in monitor["attempts"].values()), monitor
    origin.succeed(f"{k} exec public-admission-probe -n gateway -- touch /result/stop")
    origin.succeed(f"{k} delete pod public-admission-probe -n gateway --wait=true")

relay.succeed("systemctl is-active containment-monitor.service")
relay.succeed("touch /root/stop-monitor")
relay.wait_until_succeeds("systemctl show containment-monitor.service -p ActiveState --value | grep -qx inactive", timeout=30)
monitor = json.loads(command(relay, "cat /root/containment.json"))
assert not monitor["violations"], monitor
assert len(monitor["attempts"]) == len(forbidden) and all(count >= 5 for count in monitor["attempts"].values()), monitor
client.succeed("systemctl is-active public-host-monitor.service")
client.succeed("touch /root/stop-public-host")
client.wait_until_succeeds("systemctl show public-host-monitor.service -p ActiveState --value | grep -qx inactive", timeout=30)
monitor = json.loads(command(client, "cat /root/public-host.json"))
assert monitor["attempts"].get(f"https:{private}", 0) >= 5 and not monitor["violations"], monitor
client.succeed("systemctl is-active public-admin-monitor.service")
client.succeed("touch /root/stop-public-admin")
client.wait_until_succeeds("systemctl show public-admin-monitor.service -p ActiveState --value | grep -qx inactive", timeout=30)
monitor = json.loads(command(client, "cat /root/public-admin.json"))
assert monitor["attempts"].get(f"https:{admin}", 0) >= 5 and not monitor["violations"], monitor

with subtest("private application and genuine native sign-in survive relay and Tailnet loss"):
    relay.succeed("systemctl restart haproxy.service")
    expect_status(200, direct=True)
    converge_status(200)
    relay.succeed("systemctl stop haproxy.service")
    client.fail(f"curl -sSf --connect-timeout 2 --max-time 4 --cacert {ca} --resolve origin.test:443:{settings['relayAddress']} https://origin.test/")
    expect_status(200, direct=True)
    expect_status(200, host=idm, path="/status", direct=True)
    relay.succeed("systemctl start haproxy.service")
    converge_status(200)
    origin.succeed("systemctl stop tailscaled.service")
    client.fail(f"curl -sSf --connect-timeout 2 --max-time 4 --cacert {ca} --resolve origin.test:443:{settings['relayAddress']} https://origin.test/")
    expect_status(200, direct=True)
    expect_status(302, host=private, direct=True)
    transfer(origin, client, "/root/fixture/recovery.json", "/root/recovery-private.json")
    browser(f"{settings['nodeAddress']}:{settings['nodePort']}", "private", "/root/recovery-private.json")
    save_logs()

with subtest("all Gateway access and error logs omit query, token, cookie and real OIDC secrets"):
    for gateway, label in (("household-public", "public"), ("household", "private")):
        transfer(origin, client, f"/root/{gateway}.log", "/root/gateway.log")
        client.succeed(f"{q(settings['python'])} -c " + q(
            "import json,pathlib; logs=pathlib.Path('/root/gateway.log').read_text(); "
            f"values=json.loads(pathlib.Path('/root/auth-{label}/sensitive.json').read_text()); "
            "assert values and all(value and value not in logs for value in values); "
            "assert all(value not in logs for value in ['query-secret','callback-secret','bearer-secret','cookie-secret'])"))
    origin.succeed(f"{k} delete secret kanidm-provision -n identity")
    origin.succeed("rm -f /root/fixture/recovery.json /root/fixture/recovery.log /root/fixture/idm-admin-password")
    client.succeed("rm -f /root/gateway.log /root/auth-public/sensitive.json /root/auth-private/sensitive.json")
print("EVIDENCE native-public-entry: real HAProxy/tailscaled/private Headscale/rendered Envoy/K3s, native authorization and isolation transitions exercised")
