"""Exercise rendered kubelet jobs with the real collector, locally or against K3s."""
import argparse
from contextlib import contextmanager
from copy import deepcopy
import http.server
import json
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request

import yaml


def wait_for(description, action):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            result = action()
            if result:
                return result
        except (OSError, ValueError, subprocess.CalledProcessError):
            pass
        time.sleep(1)
    raise AssertionError(description)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextmanager
def collector(binary, jobs, directory, token, health, error=""):
    port = free_port()
    config = directory / "scrape.json"
    config.write_text(json.dumps({"global": {"scrape_interval": "1s", "scrape_timeout": "1s"},
                                  "scrape_configs": jobs}))
    with (directory / "collector.log").open("w+") as log:
        process = subprocess.Popen([
            binary, f"-promscrape.config={config}", "-promscrape.config.strictParse=true",
            f"-storageDataPath={directory / 'data'}", "-storage.minFreeDiskSpaceBytes=1MB",
            f"-httpListenAddr=127.0.0.1:{port}", "-search.latencyOffset=0s",
        ], stdout=log, stderr=log)
        def api(path):
            with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=3) as response:
                return json.load(response)["data"]
        try:
            def ready():
                assert process.poll() is None, "collector exited before the TLS assertion"
                targets = api("/api/v1/targets")["activeTargets"]
                return (len(targets) == len(jobs)
                        and all(t["health"] == health and error in t.get("lastError", "") for t in targets))
            wait_for(f"collector targets did not become {health} ({error})", ready)
            yield api
        finally:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            log.seek(0)
            assert token not in log.read(), "collector leaked the bearer token into its logs"


def openssl(*args):
    subprocess.run(["openssl", *map(str, args)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def portable(binary, originals, root):
    # The files and discovered addresses are replaced, not the production TLS/auth settings.
    token = "fixture-kubelet-bearer-do-not-log"
    (root / "token").write_text(token)
    for ca in ("trusted", "rogue"):
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                "-subj", f"/CN={ca}", "-keyout", root / f"{ca}.key", "-out", root / f"{ca}.crt")
    for case, ca, ip in (("valid", "trusted", "127.0.0.1"), ("wrong-ca", "rogue", "127.0.0.1"),
                          ("wrong-name", "trusted", "127.0.0.2")):
        directory = root / case
        directory.mkdir()
        openssl("req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=kubelet",
                "-keyout", directory / "key", "-out", directory / "csr")
        (directory / "extensions").write_text(f"subjectAltName=IP:{ip}\nextendedKeyUsage=serverAuth\n")
        openssl("x509", "-req", "-in", directory / "csr", "-CA", root / f"{ca}.crt",
                "-CAkey", root / f"{ca}.key", "-set_serial", "1", "-days", "1",
                "-extfile", directory / "extensions", "-out", directory / "cert")
        requests = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append((self.path, self.headers.get("Authorization")))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"fixture_kubelet_metric 1\n")
            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(directory / "cert", directory / "key")
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        jobs = deepcopy(originals)
        for job in jobs:
            job.pop("kubernetes_sd_configs")
            job["static_configs"] = [{"targets": [f"127.0.0.1:{server.server_port}"]}]
            job["bearer_token_file"] = str(root / "token")
            job["tls_config"]["ca_file"] = str(root / "trusted.crt")
        try:
            with collector(binary, jobs, directory, token, "up" if case == "valid" else "down",
                           "" if case == "valid" else "x509:"):
                if case == "valid":
                    assert {path for path, _ in requests} == {"/metrics", "/metrics/cadvisor"}
                    assert all(auth == f"Bearer {token}" for _, auth in requests), "valid server did not receive authentication"
                else:
                    assert not requests, f"{case} endpoint received HTTP (and potentially credentials) before TLS verification"
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        print(f"EVIDENCE rendered kubelet/cAdvisor collector jobs: {case}; bearer token never sent to rejected TLS endpoints or logged")


def native(binary, originals, objects, root, k3s, kubeconfig):
    kubectl = [k3s, "kubectl", "--kubeconfig", kubeconfig]
    def k(*args):
        return subprocess.check_output([*kubectl, *args], text=True)
    access = [obj for obj in objects if (obj["kind"], obj["metadata"]["name"]) in {
        ("ServiceAccount", "victoriametrics"), ("ClusterRole", "monitoring-victoriametrics"),
        ("ClusterRoleBinding", "monitoring-victoriametrics")}]
    assert len(access) == 3
    access.insert(0, {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "monitoring"}})
    subprocess.run([*kubectl, "apply", "-f", "-"], input=json.dumps({"apiVersion": "v1", "kind": "List", "items": access}),
                   text=True, check=True, stdout=subprocess.DEVNULL)
    token = k("-n", "monitoring", "create", "token", "victoriametrics", "--duration=10m").strip()
    (root / "token").write_text(token)
    ca = wait_for("projected ServiceAccount CA was not published", lambda: k(
        "-n", "monitoring", "get", "configmap", "kube-root-ca.crt", "-o", "json"))
    (root / "ca.crt").write_text(json.loads(ca)["data"]["ca.crt"])
    identity = "--as=system:serviceaccount:monitoring:victoriametrics"
    assert k("auth", "can-i", "get", "nodes", "--subresource=metrics", identity).strip() == "yes"
    denied = subprocess.run([*kubectl, "auth", "can-i", "get", "nodes", "--subresource=proxy", identity], capture_output=True, text=True)
    assert denied.returncode != 0 and denied.stdout.strip() == "no", "collector gained nodes/proxy authority"
    # Same jobs, CA and token as the Pod; only give external discovery its API endpoint/credentials.
    jobs = deepcopy(originals)
    for job in jobs:
        job["bearer_token_file"] = str(root / "token")
        job["tls_config"]["ca_file"] = str(root / "ca.crt")
        for discovery in job["kubernetes_sd_configs"]:
            discovery.update(api_server="https://127.0.0.1:6443", bearer_token_file=str(root / "token"),
                             tls_config={"ca_file": str(root / "ca.crt")})
    nodes = json.loads(k("get", "nodes", "-o", "json"))["items"]
    assert len(nodes) == 1, "the native drill requires one K3s node"
    node = nodes[0]
    with collector(binary, jobs, root, token, "up") as api:
        for metric, job, expected in (
            ("up", "kubelet", 1),
            ("up", "cadvisor", 1),
            ("machine_cpu_cores", "cadvisor", float(node["status"]["capacity"]["cpu"])),
        ):
            def matches_node():
                result = api("/api/v1/query?" + urllib.parse.urlencode({
                    "query": f'{metric}{{job="{job}"}}'}))["result"]
                return (len(result) == 1
                        and result[0]["metric"].get("node") == node["metadata"]["name"]
                        and float(result[0]["value"][1]) == expected)
            wait_for(f"{job} did not report {metric}={expected} for the discovered K3s node", matches_node)
    print("EVIDENCE real K3s kubelet and cAdvisor scraped with projected server CA, discovered SAN-verified node IP and get nodes/metrics only")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rendered", type=Path)
    parser.add_argument("--collector", default="victoria-metrics")
    parser.add_argument("--k3s")
    parser.add_argument("--kubeconfig", default="/etc/rancher/k3s/k3s.yaml")
    args = parser.parse_args()
    objects = [obj for path in args.rendered.glob("*.yaml") for obj in yaml.safe_load_all(path.read_text()) if obj]
    deployment = next(obj for obj in objects if obj["kind"] == "Deployment" and obj["metadata"]["name"] == "victoriametrics")
    image = next(c["image"] for c in deployment["spec"]["template"]["spec"]["containers"] if c["name"] == "victoriametrics")
    version = image.split("@")[0].rsplit(":", 1)[1].removeprefix("v")
    binary_version = subprocess.check_output([args.collector, "-version"], text=True, stderr=subprocess.STDOUT)
    assert re.search(r"(?<![\d.])" + re.escape(version) + r"(?![\d.])", binary_version), "collector does not match the production image release"
    config = next(obj for obj in objects if obj["kind"] == "ConfigMap" and obj["metadata"]["name"] == "victoriametrics-scrape")
    jobs = [job for job in json.loads(config["data"]["scrape.json"])["scrape_configs"] if job["job_name"] in ("kubelet", "cadvisor")]
    assert len(jobs) == 2
    with tempfile.TemporaryDirectory(prefix="monitoring-kubelet-tls-") as temporary:
        root = Path(temporary)
        if args.k3s:
            native(args.collector, jobs, objects, root, args.k3s, args.kubeconfig)
        else:
            portable(args.collector, jobs, root)


if __name__ == "__main__":
    main()
