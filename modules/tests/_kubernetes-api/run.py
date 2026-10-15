"""Owned pinned K3s, real controllers/protocols and required Chainsaw safety scenarios."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import platform
import secrets
import signal
import subprocess
import sys
import tempfile
import time
import uuid

import yaml
from report import ARGO_CRDS, ARGO_RECOVERY_APPS, ARGO_RECOVERY_JOBS, ENVOY_READINESS_STATS, REQUIRED_SCENARIOS, argo_recovery_witness, check_acceptance, check_report, classify_docker_error, classify_kubectl_error, classify_network_policy_error, crd_condition_witness, envoy_readiness_witness, gateway_owned_workloads, gateway_prerequisite_witness, network_policy_witness, sanitize_tests

OWNER_LABEL = "verification.homelab/fixture"


def capture_envoy_readiness(kubectl_command, env, workloads):
    """One owned proxy, readonly fixed endpoints, bounded localhost-only forwarding."""
    import re
    import selectors
    from urllib.parse import urlencode

    _, pods = gateway_owned_workloads(workloads)
    proxies = [pod for pod in pods if all(
        ((pod.get("metadata") or {}).get("labels") or {}).get(key) == value for key, value in (
            ("gateway.envoyproxy.io/owning-gateway-name", "household"),
            ("gateway.envoyproxy.io/owning-gateway-namespace", "gateway"),
        )) and any(container.get("name") == "envoy" for container in
                   (pod.get("spec") or {}).get("containers") or [])]
    if not proxies:
        return {"status": "unavailable", "capturePhase": "before-cleanup", "errorCategory": "owned-proxy-absent"}
    pod = proxies[0]
    container = next(container for container in pod["spec"]["containers"] if container.get("name") == "envoy")
    witness = {
        "status": "unavailable", "capturePhase": "before-cleanup",
        "probeMatches": {kind: (container.get(kind) or {}).get("httpGet") ==
                         {"path": "/ready", "port": 19003, "scheme": "HTTP"}
                         for kind in ("startupProbe", "readinessProbe")},
        "responses": {},
    }
    # Unlike port-forward, this native API proxy probes the Pod IP from inside
    # the owned K3s node network (where its API server and kubelet both execute).
    try:
        api_probe = subprocess.run([
            *kubectl_command, "get", "--raw",
            "/api/v1/namespaces/gateway/pods/" + pod["metadata"]["name"] + ":19003/proxy/ready",
            "--request-timeout=3s",
        ], env=env, capture_output=True, text=True, timeout=5)
        witness["apiReadiness"] = {
            "returnCode": api_probe.returncode,
            "errorCategory": classify_kubectl_error(api_probe.stderr) if api_probe.returncode else None,
        }
    except Exception as error:
        witness["apiReadiness"] = {"errorCategory": "timeout" if isinstance(error, subprocess.TimeoutExpired) else "transport"}
    process = None
    try:
        # The admin listener stays private. No Service/Pod/spec mutations or new
        # tools/images: kubectl uses the same explicit disposable fixture context.
        process = subprocess.Popen([
            *kubectl_command, "-n", "gateway", "port-forward", "pod/" + pod["metadata"]["name"],
            "--address=127.0.0.1", ":19000", ":19003", "--pod-running-timeout=5s",
            "--request-timeout=10s",
        ], env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        ports = {}
        buffer = b""
        deadline = time.monotonic() + 10
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while len(ports) != 2:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise TimeoutError()
                chunk = os.read(process.stdout.fileno(), 4096)
                if not chunk:
                    raise RuntimeError("forward-exited")
                buffer += chunk
                if len(buffer) > 8192:
                    raise ValueError("forward-output-limit")
                for match in re.finditer(rb"Forwarding from 127\.0\.0\.1:([0-9]+) -> (19000|19003)\n", buffer):
                    ports[int(match[2])] = int(match[1])
        raw = {}
        stats_filter = "^(" + "|".join(re.escape(name) for name in ENVOY_READINESS_STATS) + ")$"
        for key, port, path in (
            ("readiness", 19003, "/ready"),
            ("serverInfo", 19000, "/server_info"),
            ("stats", 19000, "/stats?" + urlencode({"format": "json", "filter": stats_filter})),
        ):
            try:
                response = subprocess.run([
                    "curl", "--noproxy", "*", "--silent", "--show-error",
                    "--connect-timeout", "2", "--max-time", "3", "--max-filesize", "16384",
                    "--write-out", "\n%{http_code}", f"http://127.0.0.1:{ports[port]}{path}",
                ], env=env, capture_output=True, timeout=5)
                if response.returncode:
                    witness["responses"][key] = {
                        "returnCode": response.returncode,
                        "errorCategory": {7: "connection-refused", 28: "timeout", 63: "response-size-limit"}.get(
                            response.returncode, "transport"),
                    }
                    continue
                body, _, status = response.stdout.rpartition(b"\n")
                if len(body) > 16384 or len(status) != 3 or not status.isdigit() or not 100 <= int(status) <= 599:
                    raise ValueError("unexpected-response")
                witness["responses"][key] = {"httpStatus": int(status)}
                if key != "readiness" and status == b"200":
                    raw[key] = json.loads(body)
            except Exception as error:
                witness["responses"].setdefault(key, {})["errorCategory"] = (
                    "timeout" if isinstance(error, subprocess.TimeoutExpired) else
                    "invalid-response" if isinstance(error, ValueError) else "transport")
        witness.update(envoy_readiness_witness(raw.get("serverInfo", {}), raw.get("stats", {})))
        witness["status"] = "observed" if any("httpStatus" in response for response in witness["responses"].values()) else "unavailable"
    except Exception as error:
        witness["errorCategory"] = "forward-timeout" if isinstance(error, TimeoutError) else "forward-or-response-unavailable"
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            process.stdout.close()
            witness["forwardStopped"] = True
    return witness


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-settings", required=True, type=Path, help="Complete materialized fixture JSON; bundled by the x86_64-linux app. Other frontends require an explicit compatible closure.")
    parser.add_argument("--docker-context", required=True, help="Explicit local Unix-socket Docker context")
    parser.add_argument("--report", required=True, type=Path, help="New sanitized JSON output (refuses overwrite)")
    parser.add_argument("--test-dir", type=Path)
    parser.add_argument("--exclude-test-regex", default="")
    parser.add_argument("--selector", default="")
    parser.add_argument("--remove-gateway-tls-cel", action="store_true")
    parser.add_argument("--argo-mutation", choices=["always-healthy", "source-error-ignored", "cascade-retained"], default="")
    args = parser.parse_args()
    settings_path = args.fixture_settings.resolve()
    settings = json.loads(settings_path.read_text())
    if args.test_dir is None:
        args.test_dir = Path(settings["scenarios"])
    scoped = args.test_dir.resolve() != Path(settings["scenarios"]).resolve() or bool(args.exclude_test_regex or args.selector)
    output = args.report.open("x", encoding="utf-8")
    os.chmod(args.report, 0o600)
    env = {key: value for key, value in os.environ.items() if not key.startswith(("DOCKER_", "FIXTURE_", "HOMELAB_", "ARGOCD_RUNTIME_")) and key not in ("KUBECONFIG", "KUBERNETES_MASTER")}
    token = uuid.uuid4().hex
    name = f"homelab-api-{token}"
    network = f"{name}-network"
    required = REQUIRED_SCENARIOS
    report = {
        "fixture": name, "scenario": "kubernetes-native-safety", "requiredScenarios": required,
        "image": settings["image"], "architecture": platform.machine(), "fixtureArchitecture": "x86_64-linux",
        "emulatedFixture": platform.machine().lower() not in ("x86_64", "amd64"), "nativeARMProof": False,
        "kubectlPackageVersion": settings.get("kubectlVersion", "unknown"),
        "mutation": {"gatewayTLSCEL": args.remove_gateway_tls_cel, "argo": args.argo_mutation},
        "fullAcceptance": False, "scoped": scoped, "status": "failed",
        "cleanup": {"containers": False, "volumes": False, "network": False, "credentials": False},
        "timingsSeconds": {},
    }
    report["secretScript"] = {key: settings["secret"][key] for key in ("provenance", "scriptSha256", "system", "deployedSystem", "nativePlatformOverride") if key in settings["secret"]}
    temp = tempfile.TemporaryDirectory(prefix="homelab-api-")
    work = Path(temp.name)
    work.chmod(0o700)
    docker = [settings["docker"]]
    phase = "local-docker-transport"
    started = time.monotonic()
    last_checkpoint_phase = None
    transport_ready = False
    network_attempted = False

    def checkpoint(*, force=False):
        nonlocal last_checkpoint_phase
        if not force and last_checkpoint_phase == phase:
            return
        elapsed = round(time.monotonic() - started, 3)
        snapshot = dict(report)
        # No intermediate artifact can represent completed acceptance/cleanup.
        snapshot.update(status="failed", fullAcceptance=False, progress={"phase": phase, "elapsedSeconds": elapsed})
        output.seek(0)
        json.dump(snapshot, output, indent=2)
        output.write("\n")
        output.truncate()
        output.flush()
        os.fsync(output.fileno())
        print(json.dumps({"event": "verification-progress", "phase": phase, "elapsedSeconds": elapsed, "suite": report.get("currentSuite"), "executed": report.get("executed", [])}, sort_keys=True), flush=True)
        last_checkpoint_phase = phase

    def run(command, *, timeout=60, check=True, input=None):
        checkpoint()
        result = subprocess.run(command, env=env, cwd=work, input=input, text=True, capture_output=True, timeout=timeout)
        if check and result.returncode:
            report["commandFailure"] = {"program": Path(command[0]).name, "returnCode": result.returncode}
            if phase in ("network-policy-apply", "network-policy-readiness"):
                report["commandFailure"]["errorCategory"] = classify_network_policy_error(result.stderr)
            if phase == "argo-fixture-prerequisites":
                report["commandFailure"]["errorCategory"] = classify_kubectl_error(result.stderr)
                marker = "HOMELAB_NATIVE_ARGO_ERROR_LINE="
                for diagnostic in result.stderr.splitlines():
                    source_line = diagnostic.removeprefix(marker)
                    if diagnostic.startswith(marker) and source_line.isascii() and source_line.isdigit() and len(source_line) <= 6:
                        report["commandFailure"]["sourceLine"] = int(source_line)
            if phase == "gateway-fixture-prerequisites":
                # Fixed numeric witness written by gateway-case's ERR trap.
                report["commandFailure"]["errorCategory"] = classify_kubectl_error(result.stderr)
                report["commandFailure"]["dockerErrorCategory"] = classify_docker_error(result.stderr)
                try:
                    witness = json.loads((work / "gateway" / "case-failure.json").read_text())
                except (OSError, json.JSONDecodeError):
                    witness = {}
                if isinstance(witness, dict):
                    report["gatewayCaseFailure"] = {
                        key: witness[key] for key in ("scriptLine", "callerLine", "returnCode")
                        if type(witness.get(key)) is int and 0 <= witness[key] <= 999999
                    }
                    frames = witness.get("frames")
                    if isinstance(frames, list):
                        report["gatewayCaseFailure"]["frames"] = [line for line in frames if type(line) is int and 0 <= line <= 999999][:16]
                try:
                    functions = json.loads((work / "gateway" / "case-failure-functions.json").read_text())
                except (OSError, json.JSONDecodeError):
                    functions = []
                if isinstance(functions, list):
                    report.setdefault("gatewayCaseFailure", {})["functions"] = [name for name in functions if isinstance(name, str) and name.isidentifier() and len(name) <= 64][:16]
            if command[0] == settings["docker"] and "errorCategory" not in report["commandFailure"]:
                # Public pinned references and a fixed category only; never daemon output.
                report["commandFailure"]["subcommand"] = command[len(docker)]
                report["commandFailure"]["target"] = next((part for part in command if "@sha256:" in part), None)
                report["commandFailure"]["errorCategory"] = classify_docker_error(result.stderr)
            raise RuntimeError("command-failed")
        return result

    def d(*command, **options):
        return run(docker + list(command), **options)

    def kubectl(*command, **options):
        if "KUBECONFIG" in env:
            return run([settings["kubectl"], "--context", name, *command], **options)
        stdin = ("--interactive",) if options.get("input") is not None else ()
        return d("exec", *stdin, name, "kubectl", "--kubeconfig", "/etc/rancher/k3s/k3s.yaml", "--context", "default", *command, **options)

    def create_container(container, image, command, address=None, hosts=(), privileged=False, publish=False):
        options = ["create", "--platform", "linux/amd64", "--name", container, "--label", f"{OWNER_LABEL}={token}", "--network", network]
        if address:
            options += ["--ip", address]
        for host in hosts:
            options += ["--add-host", f"{host}:{env['FIXTURE_NODE_IP']}"]
        if privileged:
            options += ["--privileged"]
        if publish:
            options += ["--publish", "127.0.0.1::6443"]
        d(*options, image, *command)
        d("start", container)

    def interrupt(signum, frame):
        raise RuntimeError("interrupted")

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        supplied = settings["requiredScenarios"]
        if len(supplied) != len(required) or set(supplied) != set(required):
            raise ValueError("required-scenario-inventory")
        context = json.loads(run(docker + ["context", "inspect", args.docker_context]).stdout)[0]
        endpoint = context["Endpoints"]["docker"]["Host"]
        if not endpoint.startswith("unix:///") or "\n" in endpoint:
            raise ValueError("nonlocal-docker-transport")
        docker_config = work / "docker"
        docker_config.mkdir(mode=0o700)
        docker += ["--host", endpoint, "--config", str(docker_config)]
        d("info")
        transport_ready = True
        private_home = work / "home"
        private_home.mkdir(mode=0o700)
        env.update({"HOME": str(private_home), "XDG_CONFIG_HOME": str(private_home / ".config"), "XDG_CACHE_HOME": str(private_home / ".cache"), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})
        env.update({
            "FIXTURE_TOKEN": token, "FIXTURE_DOCKER": settings["docker"], "FIXTURE_DOCKER_HOST": endpoint,
            "FIXTURE_DOCKER_CONFIG": str(docker_config), "FIXTURE_NODE": name, "FIXTURE_NETWORK": network,
            "FIXTURE_TRUSTED": f"{name}-trusted", "FIXTURE_STRANGER": f"{name}-stranger",
            "FIXTURE_WORK": str(work), "FIXTURE_SETTINGS": str(settings_path), "FIXTURE_ARGO_MUTATION": args.argo_mutation,
            "KUBECTL": settings["kubectl"], "PATH": settings["path"] + os.pathsep + env.get("PATH", ""),
        })
        phase = "image-fetch"
        image_start = time.monotonic()
        report["imageCached"] = d("image", "inspect", settings["image"], check=False).returncode == 0
        if not report["imageCached"]:
            d("pull", "--platform", "linux/amd64", settings["image"], timeout=600)
        for image in settings["images"]:
            d("load", "--input", image["archive"], timeout=600)
        registry_images = set(settings.get("registryImages", []))
        # Inventory immutable upstream image references; this is transport, not policy evaluation.
        def images_in(value):
            if isinstance(value, dict):
                for key, item in value.items():
                    if key == "image" and isinstance(item, str) and "@sha256:" in item:
                        registry_images.add(item)
                    else:
                        images_in(item)
            elif isinstance(value, list):
                for item in value:
                    images_in(item)
        for directory in settings.get("registryManifestDirectories", []):
            for path in Path(directory).rglob("*"):
                if path.is_file() and path.suffix in (".json", ".yaml", ".yml"):
                    for document in yaml.safe_load_all(path.read_text()):
                        images_in(document)
        registry_archives = []
        for index, image in enumerate(sorted(registry_images)):
            if "@sha256:" not in image:
                raise ValueError("unpinned-registry-image")
            d("pull", "--platform", "linux/amd64", image, timeout=600)
            archive = work / f"registry-{index}.tar"
            d("save", "--platform", "linux/amd64", "--output", str(archive), image, timeout=600)
            registry_archives.append(archive)
        report["timingsSeconds"]["imageFetch"] = round(time.monotonic() - image_start, 3)
        phase = "cluster-setup"
        setup_start = time.monotonic()
        network_attempted = True
        # Containers get fixed addresses, which Docker before 29.1 accepts only
        # on a network whose subnet was configured explicitly.
        for attempt in range(8):
            subnet = ipaddress.ip_network(f"10.213.{secrets.randbelow(256)}.0/24")
            created = d("network", "create", "--label", f"{OWNER_LABEL}={token}", "--subnet", str(subnet), network, check=False)
            if created.returncode == 0:
                break
            if classify_docker_error(created.stderr) != "address-pool":
                d("network", "create", "--label", f"{OWNER_LABEL}={token}", "--subnet", str(subnet), network)
        else:
            raise RuntimeError("network-subnet-unavailable")
        net = json.loads(d("network", "inspect", network).stdout)[0]
        if ipaddress.ip_network(net["IPAM"]["Config"][0]["Subnet"]) != subnet:
            raise ValueError("network-subnet-mismatch")
        def address(offset):
            return str(subnet.network_address + offset)
        env.update({"FIXTURE_NODE_IP": address(10), "FIXTURE_TRUSTED_IP": address(11), "FIXTURE_STRANGER_IP": address(20)})
        create_container(name, settings["image"], ["server", "--node-name", "compute-1", "--disable", "traefik", "--disable", "servicelb", "--disable", "metrics-server", "--disable", "local-storage", "--disable-network-policy", "--kube-proxy-arg=proxy-mode=nftables"], address(10), privileged=True, publish=True)
        phase = "api-readiness"
        # Bounded lifecycle readiness only. Scenario convergence belongs to Chainsaw/native wait.
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                ready = kubectl("get", "--raw=/readyz", check=False, timeout=10)
            except subprocess.TimeoutExpired:
                continue
            if ready.returncode == 0 and ready.stdout.strip() == "ok":
                break
            time.sleep(1)
        else:
            raise RuntimeError("readiness-timeout")
        version = json.loads(kubectl("get", "--raw=/version").stdout)
        if version["gitVersion"] != "v1.35.8+k3s1":
            raise ValueError("target-version-mismatch")
        phase = "disposable-kubeconfig"
        info = json.loads(d("inspect", name).stdout)[0]
        ports = info["NetworkSettings"]["Ports"]["6443/tcp"]
        if len(ports) != 1 or ports[0]["HostIp"] != "127.0.0.1":
            raise ValueError("nonlocal-api-endpoint")
        original = yaml.safe_load(d("exec", name, "cat", "/etc/rancher/k3s/k3s.yaml").stdout)
        config = {
            "apiVersion": "v1", "kind": "Config", "current-context": name,
            "clusters": [{"name": name, "cluster": {"server": f"https://127.0.0.1:{int(ports[0]['HostPort'])}", "certificate-authority-data": original["clusters"][0]["cluster"]["certificate-authority-data"]}}],
            "contexts": [{"name": name, "context": {"cluster": name, "user": name}}],
            "users": [{"name": name, "user": {key: original["users"][0]["user"][key] for key in ("client-certificate-data", "client-key-data")}}],
        }
        kubeconfig = work / "kubeconfig"
        kubeconfig.write_text(yaml.safe_dump(config))
        kubeconfig.chmod(0o600)
        env["KUBECONFIG"] = str(kubeconfig)
        phase = "owned-image-import"
        archives = [image["archive"] for image in settings["images"] if image["reference"] in settings["kubernetesImages"]] + registry_archives
        for index, archive in enumerate(archives):
            dest = f"/tmp/fixture-image-{index}.tar"
            d("cp", str(archive), f"{name}:{dest}", timeout=600)
            d("exec", name, "ctr", "--address", "/run/k3s/containerd/containerd.sock", "--namespace", "k8s.io", "images", "import", dest, timeout=600)
            d("exec", name, "rm", "-f", dest)
        # The production packet enforcer, not K3s's retired embedded controller,
        # must be ready before the controller and source-isolation scenarios.
        phase = "network-policy-mounts"
        # HostToContainer needs a propagation-capable netns mount in this
        # owned Docker node, not a change to the runner's host mounts.
        d("exec", name, "mkdir", "-p", "/var/run/netns")
        d("exec", name, "mount", "--bind", "/var/run/netns", "/var/run/netns")
        d("exec", name, "mount", "--make-rshared", "/var/run/netns")
        phase = "network-policy-apply"
        kubectl("apply", "-f", settings["networkPolicy"])
        phase = "network-policy-readiness"
        kubectl("rollout", "status", "daemonset/kube-network-policies", "-n", "kube-system", "--timeout=180s", timeout=190)
        phase = "owned-client-create"
        tools = settings["gateway"]["toolsImage"]
        hosts = settings["gateway"].get("hostnames", [])
        for suffix, offset in [("trusted", 11), ("stranger", 20)]:
            create_container(f"{name}-{suffix}", tools, ["/bin/sh", "-c", "sleep infinity"], address(offset), hosts)
        for container in settings["containers"]:
            suffix = container["suffix"]
            container_name = f"{name}-{suffix}"
            ip = address(container["ip"]) if container.get("ip") is not None else None
            create_container(container_name, container["image"], container.get("command", ["/bin/sh", "-c", "sleep infinity"]), ip)
            key = "FIXTURE_" + suffix.upper().replace("-", "_")
            env[key] = container_name
            if ip:
                env[key + "_IP"] = ip
        phase = "gateway-crd-admission"
        crd = Path(settings["crd"]).read_text()
        kubectl("apply", "--server-side", "-f", "-", input=crd)
        kubectl("wait", "--for=condition=Established", "--timeout=60s", "crd/gateways.gateway.networking.k8s.io", timeout=70)
        for family, script in settings["setup"].items():
            phase = f"{family}-fixture-prerequisites"
            run([script], timeout=1200)
        # Apply the counterfactual after controller setup so installing the full
        # canonical CRD set cannot accidentally restore the removed CEL rule.
        phase = "gateway-crd-counterfactual"
        if args.remove_gateway_tls_cel:
            obj = yaml.safe_load(crd)
            removed = []
            for version in obj["spec"]["versions"]:
                listener = version["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["listeners"]
                rules = listener["x-kubernetes-validations"]
                target = [rule for rule in rules if rule.get("message") == "tls must not be specified for protocols ['HTTP', 'TCP', 'UDP']"]
                if len(target) != 1:
                    raise ValueError("mutation-rule-missing-or-ambiguous")
                rules.remove(target[0])
                removed.append(version["name"])
            if "v1" not in removed:
                raise ValueError("mutation-v1-rule-missing")
            crd = yaml.safe_dump(obj)
            kubectl("apply", "--server-side", "-f", "-", input=crd)
            kubectl("wait", "--for=condition=Established", "--timeout=60s", "crd/gateways.gateway.networking.k8s.io", timeout=70)
        report["timingsSeconds"]["setup"] = round(time.monotonic() - setup_start, 3)
        phase = "chainsaw-scenarios"
        scenario_start = time.monotonic()
        directories = [str(args.test_dir.resolve())] if scoped else settings["testDirectories"]
        raw = {"tests": []}
        for index, directory in enumerate(directories):
            # Explicit native invocations preserve suite dependencies; Chainsaw
            # only guarantees step order within a Test, not discovery order.
            report_name = f"chainsaw-{index}"
            declared = [
                yaml.safe_load(path.read_text())["metadata"]["name"]
                for path in sorted(Path(directory).rglob("chainsaw-test.yaml"))
            ]
            report["currentSuite"] = {"index": index + 1, "scenarios": [name if name in required else "unexpected" for name in declared]}
            checkpoint(force=True)
            remaining = 3600 - (time.monotonic() - scenario_start)
            if remaining <= 0:
                raise RuntimeError("scenario-deadline")
            result = run([
                settings["chainsaw"], "test", directory,
                "--kube-context", name, "--parallel", "1", "--repeat-count", "1", "--fail-fast",
                "--report-format", "JSON", "--report-path", str(work), "--report-name", report_name,
                "--apply-timeout", "60s", "--assert-timeout", "180s", "--cleanup-timeout", "60s",
                "--exec-timeout", "600s", "--delete-timeout", "60s", "--kube-request-timeout", "30s",
                "--exclude-test-regex", args.exclude_test_regex, "--selector", args.selector,
                "--no-color", "--remarshal",
            ], timeout=remaining, check=False)
            phase = "scenario-report"
            chunk = json.loads((work / f"{report_name}.json").read_text())
            raw["tests"].extend(chunk.get("tests") or [])
            report["executed"] = sanitize_tests(raw["tests"])
            checkpoint(force=True)
            if result.returncode:
                # Read fixed numeric witnesses before owned cleanup; never retain
                # arbitrary command output, Secret values or request metadata.
                for field, relative, keys in (
                    ("gatewayCaseFailure", "gateway/case-failure.json", ("scriptLine", "callerLine", "returnCode")),
                    ("gatewayBrowserFailure", "gateway/browser-failure.json", ("httpStatus", "firstLine", "lastLine")),
                    ("secretFailure", "secret-failure.json", ("errorLine", "callerLine", "outerLine")),
                ):
                    witness_path = work / relative
                    try:
                        witness = json.loads(witness_path.read_text())
                    except (OSError, json.JSONDecodeError):
                        continue
                    if isinstance(witness, dict):
                        report[field] = {
                            key: witness[key] for key in keys
                            if type(witness.get(key)) is int and 0 <= witness[key] <= 999999
                        }
                native_failure = (result.stderr + json.dumps([
                    operation.get("failure")
                    for test in chunk.get("tests") or []
                    for step in test.get("steps") or []
                    for operation in step.get("operations") or []
                    if operation.get("status") == "failed"
                ])).lower()
                report["nativeFailureHints"] = [
                    hint for hint, marker in (
                        ("null-length", "length"),
                        ("invalid-type", "invalid type"),
                        ("nil-value", "<nil>"),
                        ("unknown-variable", "unknown key"),
                        ("missing-binding", "not found"),
                    ) if marker in native_failure
                ]
                raise RuntimeError("chainsaw-exit-failure")
            check_report(chunk, declared)
            phase = "chainsaw-scenarios"
        report["timingsSeconds"]["scenario"] = round(time.monotonic() - scenario_start, 3)
        phase = "scenario-report"
        report["executed"] = sanitize_tests(raw["tests"])
        check_report(raw, required)
        if scoped:
            raise ValueError("scoped-execution-not-full-acceptance")
        if args.remove_gateway_tls_cel or args.argo_mutation:
            raise ValueError("negative-mutation-unexpectedly-passed")
        report["fullAcceptance"] = True
        report["status"] = "passed"
    except (Exception, KeyboardInterrupt) as error:
        report["failurePhase"] = phase
        allowed = {
            "nonlocal-docker-transport", "command-failed", "interrupted", "readiness-timeout", "target-version-mismatch", "nonlocal-api-endpoint",
            "mutation-rule-missing-or-ambiguous", "mutation-v1-rule-missing", "required-scenario-inventory", "scenario-coverage", "step-coverage", "scenario-failure-or-skip",
            "chainsaw-exit-failure", "scoped-execution-not-full-acceptance", "negative-mutation-unexpectedly-passed", "unpinned-registry-image",
            "scenario-deadline",
        }
        report["failureReason"] = str(error) if isinstance(error, (ValueError, RuntimeError)) and str(error) in allowed else type(error).__name__
        if phase == "gateway-fixture-prerequisites" and "KUBECONFIG" in env:
            # Read only the owned fixture context before cleanup; no events,
            # logs, Secrets or arbitrary API fields survive the sanitizer.
            observed = {}
            unavailable = {}
            for key, resource in (
                ("resources", ["gatewayclass/envoy", "gateway/household", "envoyproxy/household",
                               "clienttrafficpolicy/trusted-edges", "-n", "gateway"]),
                ("workloads", ["deployments,replicasets,pods", "-n", "gateway"]),
                ("node", ["node/compute-1"]),
            ):
                try:
                    result = kubectl("get", *resource, "--ignore-not-found", "-o", "json",
                                     "--request-timeout=10s", timeout=15, check=False)
                    if result.returncode:
                        unavailable[key] = {"returnCode": result.returncode,
                                            "errorCategory": classify_kubectl_error(result.stderr)}
                    else:
                        observed[key] = json.loads(result.stdout) if result.stdout.strip() else {}
                except Exception as witness_error:
                    unavailable[key] = {"type": type(witness_error).__name__}
            try:
                expectation = json.loads((work / "gateway" / "condition-wait.json").read_text())
            except (OSError, json.JSONDecodeError):
                expectation = {}
            try:
                report["gatewayPrerequisiteWitness"] = gateway_prerequisite_witness(
                    observed.get("resources", {}), observed.get("workloads", {}),
                    observed.get("node", {}), expectation)
                report["gatewayPrerequisiteWitness"].update(
                    status="observed" if observed else "unavailable",
                    capturePhase="before-cleanup", unavailable=unavailable)
            except Exception as witness_error:
                report["gatewayPrerequisiteWitness"] = {
                    "status": "unavailable", "type": type(witness_error).__name__,
                    "capturePhase": "before-cleanup",
                }
            try:
                report["gatewayEnvoyReadinessWitness"] = capture_envoy_readiness(
                    [settings["kubectl"], "--context", name], env, observed.get("workloads", {}))
            except Exception as witness_error:
                report["gatewayEnvoyReadinessWitness"] = {
                    "status": "unavailable", "type": type(witness_error).__name__,
                    "capturePhase": "before-cleanup",
                }
            checkpoint(force=True)
        if phase in ("network-policy-apply", "network-policy-readiness") and "KUBECONFIG" in env:
            # Readonly, bounded failure evidence before the owned node is removed.
            # Never persist native messages/logs, credentials, or arbitrary names.
            observed = {}
            unavailable = {}
            for key, resource in (
                ("daemonset", ["daemonset", "kube-network-policies"]),
                ("pods", ["pods", "-l", "app.kubernetes.io/name=kube-network-policies"]),
                ("events", ["events"]),
            ):
                try:
                    result = kubectl("-n", "kube-system", "get", *resource,
                                     "-o", "json", "--request-timeout=10s", timeout=15, check=False)
                    if result.returncode:
                        unavailable[key] = {"returnCode": result.returncode,
                                            "errorCategory": classify_kubectl_error(result.stderr)}
                    else:
                        observed[key] = json.loads(result.stdout)
                except Exception as witness_error:
                    unavailable[key] = {"type": type(witness_error).__name__}
            witness = network_policy_witness(observed.get("daemonset", {}),
                                             observed.get("pods", {}), observed.get("events", {}))
            witness.update(status="observed" if observed else "unavailable",
                           capturePhase="before-cleanup", unavailable=unavailable, logs=[])
            report["networkPolicyWitness"] = witness
            uid = (observed.get("daemonset", {}).get("metadata") or {}).get("uid")
            owned_pods = [pod for pod in observed.get("pods", {}).get("items") or [] if uid and any(
                owner.get("uid") == uid and owner.get("kind") == "DaemonSet" and owner.get("controller") is True
                for owner in (pod.get("metadata") or {}).get("ownerReferences") or []
            )][:4]
            for index, pod in enumerate(owned_pods, 1):
                for previous in (False, True):
                    log = {"podIndex": index, "previous": previous}
                    try:
                        result = kubectl("-n", "kube-system", "logs", pod["metadata"]["name"],
                                         "-c", "kube-network-policies", "--tail=100", "--limit-bytes=16384",
                                         f"--previous={str(previous).lower()}", "--request-timeout=10s",
                                         timeout=15, check=False)
                        log.update(returnCode=result.returncode,
                                   errorCategory=classify_network_policy_error(
                                       result.stderr if result.returncode else result.stdout))
                    except Exception as witness_error:
                        log["type"] = type(witness_error).__name__
                    witness["logs"].append(log)
            checkpoint(force=True)
        if phase == "argo-fixture-prerequisites" and "KUBECONFIG" in env:
            try:
                witness = run([
                    settings["kubectl"], "--context", name, "get", "crd", *ARGO_CRDS,
                    "-o", "json", "--request-timeout=10s",
                ], timeout=15, check=False)
                report["argoCrdWitness"] = (
                    {"status": "observed", "definitions": crd_condition_witness(json.loads(witness.stdout))}
                    if witness.returncode == 0 else
                    {"status": "unavailable", "returnCode": witness.returncode, "errorCategory": classify_kubectl_error(witness.stderr)}
                )
            except Exception as witness_error:
                report["argoCrdWitness"] = {"status": "unavailable", "type": type(witness_error).__name__}
            checkpoint(force=True)
        if "argo-02-retained-hook-sequencing" in report.get("currentSuite", {}).get("scenarios", []):
            try:
                report["argoRetainedWitness"] = json.loads((work / "argo" / "hook-witness.json").read_text())
            except Exception as witness_error:
                report["argoRetainedWitness"] = {"status": "unavailable", "type": type(witness_error).__name__,
                                                 "capturePhase": "native-catch-before-cleanup"}
            checkpoint(force=True)
        elif "argo-06-root-child-retirement" in report.get("currentSuite", {}).get("scenarios", []):
            try:
                report["argoRootRetirementWitness"] = json.loads(
                    (work / "argo" / "root-retirement-witness.json").read_text()
                )
            except Exception as witness_error:
                report["argoRootRetirementWitness"] = {
                    "status": "unavailable", "type": type(witness_error).__name__,
                    "capturePhase": "native-catch-before-cleanup",
                }
            checkpoint(force=True)
        elif any(scenario.startswith("argo-") for scenario in report.get("currentSuite", {}).get("scenarios", [])) and "KUBECONFIG" in env:
            try:
                witness = run([
                    settings["kubectl"], "--context", name, "-n", "argocd", "get", "applications",
                    *ARGO_RECOVERY_APPS, "--ignore-not-found", "-o", "json", "--request-timeout=10s",
                ], timeout=15, check=False)
                if witness.returncode:
                    report["argoRecoveryWitness"] = {
                        "status": "unavailable", "returnCode": witness.returncode,
                        "errorCategory": classify_kubectl_error(witness.stderr),
                    }
                else:
                    initial = (work / "argo" / "initial").read_text().strip()
                    repo_url = f"git://{env['FIXTURE_ARGO_GIT_IP']}/runtime.git"
                    jobs = run([
                        settings["kubectl"], "--context", name, "-n", "runtime", "get", "jobs",
                        *ARGO_RECOVERY_JOBS, "--ignore-not-found", "-o", "json", "--request-timeout=10s",
                    ], timeout=15, check=False)
                    fixture_sources = {
                        app: {"repoURL": repo_url, "path": path, "targetRevision": target}
                        for app, path, target in (
                            ("failed-child", "failed", "child-payload"),
                            ("missing-child", "does-not-exist", "child-payload"),
                            ("failed-root", "failed-child-root", initial),
                            ("missing-root", "missing-child-root", initial),
                        )
                    }
                    # --ignore-not-found prints nothing when no named object exists.
                    def listed(result):
                        return json.loads(result.stdout) if result.returncode == 0 and result.stdout.strip() else {"items": []}
                    report["argoRecoveryWitness"] = {
                        "status": "observed",
                        **argo_recovery_witness(listed(witness), listed(jobs), fixture_sources),
                        "lateJobsStatus": "observed" if jobs.returncode == 0 else "unavailable",
                    }
            except Exception as witness_error:
                report["argoRecoveryWitness"] = {"status": "unavailable", "type": type(witness_error).__name__}
            checkpoint(force=True)
    finally:
        cleanup_start = time.monotonic()
        phase = "cleanup"
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            if transport_ready:
                owned = d("ps", "--all", "--filter", f"label={OWNER_LABEL}={token}", "--format", "{{.ID}} {{.Names}}").stdout.splitlines()
                volumes = []
                cleanup_errors = False
                for entry in owned:
                    try:
                        container_id, container_name = entry.split(maxsplit=1)
                        info = json.loads(d("inspect", container_id).stdout)[0]
                        if info["Config"]["Labels"].get(OWNER_LABEL) != token or not (container_name == name or container_name.startswith(name + "-")):
                            raise RuntimeError("ownership-mismatch")
                        volumes += [mount["Name"] for mount in info["Mounts"] if mount["Type"] == "volume"]
                        d("rm", "--force", "--volumes", container_id, timeout=120)
                    except Exception:
                        cleanup_errors = True
                        # Continue removing the other owned containers; final
                        # presence checks still make any failed removal fatal.
                        continue
                report["cleanup"]["containers"] = not cleanup_errors and not d("ps", "--all", "--filter", f"label={OWNER_LABEL}={token}", "--format", "{{.ID}}").stdout.strip()
                report["cleanup"]["volumes"] = all((result := d("volume", "inspect", volume, check=False)).returncode != 0 and "no such volume" in result.stderr.lower() for volume in volumes)
                if network_attempted:
                    inspected = d("network", "inspect", network, check=False)
                    if inspected.returncode == 0:
                        net = json.loads(inspected.stdout)[0]
                        if net.get("Labels", {}).get(OWNER_LABEL) != token:
                            raise RuntimeError("ownership-mismatch")
                        d("network", "rm", network)
                        inspected = d("network", "inspect", network, check=False)
                    report["cleanup"]["network"] = inspected.returncode != 0 and "not found" in inspected.stderr.lower()
                else:
                    report["cleanup"]["network"] = True
            else:
                report["cleanup"].update(containers=True, volumes=True, network=True)
        except Exception:
            report["cleanup"].update(containers=False, volumes=False, network=False)
        try:
            temp.cleanup()
            report["cleanup"]["credentials"] = not work.exists()
        except Exception:
            report["cleanup"]["credentials"] = False
        if not all(report["cleanup"].values()):
            report.setdefault("failurePhase", "cleanup")
            report.setdefault("failureReason", "owned-state-cleanup-failed")
            report["status"] = "failed"
            report["fullAcceptance"] = False
        if report["status"] == "passed":
            try:
                check_acceptance(report)
            except (ValueError, TypeError, AttributeError, KeyError):
                report.update(status="failed", fullAcceptance=False,
                              failurePhase="final-report", failureReason="invalid-full-acceptance-report")
        report["timingsSeconds"]["cleanup"] = round(time.monotonic() - cleanup_start, 3)
        report["timingsSeconds"]["total"] = round(time.monotonic() - started, 3)
        output.seek(0)
        output.truncate()
        json.dump(report, output, indent=2)
        output.write("\n")
        output.close()
        print(json.dumps(report, sort_keys=True))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
