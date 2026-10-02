"""Disposable API admission only; no controller, traffic or host-runtime proof."""

import argparse
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile
import time
import uuid

import yaml


SCENARIO = "gateway-cel-admission"
OWNER_LABEL = "verification.homelab/fixture"


def check_report(raw):
    tests = raw.get("tests") or []
    if [test.get("name") for test in tests] != [SCENARIO]:
        raise ValueError("scenario-coverage")
    test = tests[0]
    steps = test.get("steps") or []
    if not steps:
        raise ValueError("step-coverage")
    if test.get("status") != "passed" or any(
        step.get("status") != "passed"
        or not step.get("operations")
        or any(op.get("status") != "passed" or op.get("failure") for op in step["operations"])
        for step in steps
    ):
        raise ValueError("scenario-failure-or-skip")


def main():
    settings = json.loads(Path(sys.argv[1]).read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker-context", required=True, help="Explicit local Unix-socket Docker context, e.g. colima")
    parser.add_argument("--report", required=True, type=Path, help="New sanitized JSON output file (refuses overwrite)")
    parser.add_argument("--test-dir", type=Path, default=Path(settings["scenarios"]))
    parser.add_argument("--exclude-test-regex", default="")
    parser.add_argument("--selector", default="")
    parser.add_argument("--remove-gateway-tls-cel", action="store_true", help="Negative probe: remove the TLS/protocol CEL rule in this disposable fixture only")
    args = parser.parse_args(sys.argv[2:])
    # Never publish kubeconfig, Docker logs or raw assertion errors as artifacts.
    output = args.report.open("x", encoding="utf-8")
    os.chmod(args.report, 0o600)
    env = {key: value for key, value in os.environ.items() if not key.startswith("DOCKER_") and key not in ("KUBECONFIG", "KUBERNETES_MASTER")}
    report = {
        "scenario": SCENARIO,
        "image": settings["image"], "architecture": platform.machine(),
        "mutation": args.remove_gateway_tls_cel, "status": "failed",
        "cleanup": {"container": True, "volumes": True, "credentials": False},
        "timingsSeconds": {},
    }
    token = uuid.uuid4().hex
    name = f"homelab-api-{token}"
    report["fixture"] = name
    temp = tempfile.TemporaryDirectory(prefix="homelab-api-")
    work = Path(temp.name)
    docker = [settings["docker"]]
    attempted_create = False
    phase = "local-docker-transport"
    started = time.monotonic()

    def run(command, *, timeout=60, check=True, input=None):
        result = subprocess.run(command, env=env, cwd=work, input=input, text=True, capture_output=True, timeout=timeout)
        if check and result.returncode:
            report["commandFailure"] = {"program": Path(command[0]).name, "returnCode": result.returncode}
            raise RuntimeError("command-failed")
        return result

    def d(*command, **options):
        return run(docker + list(command), **options)

    def kubectl(*command, **options):
        # The image supplies the matching 1.35 client, scoped to our owned container.
        stdin = ("--interactive",) if options.get("input") is not None else ()
        return d("exec", *stdin, name, "kubectl", "--kubeconfig", "/etc/rancher/k3s/k3s.yaml", "--context", "default", *command, **options)

    def interrupt(signum, frame):
        raise RuntimeError("interrupted")

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        context = json.loads(run(docker + ["context", "inspect", args.docker_context]).stdout)[0]
        endpoint = context["Endpoints"]["docker"]["Host"]
        if not endpoint.startswith("unix:///") or "\n" in endpoint:
            raise ValueError("nonlocal-docker-transport")
        docker_config = work / "docker"
        docker_config.mkdir()
        docker += ["--host", endpoint, "--config", str(docker_config)]
        d("info")
        phase = "image-fetch"
        image_start = time.monotonic()
        report["imageCached"] = d("image", "inspect", settings["image"], check=False).returncode == 0
        if not report["imageCached"]:
            d("pull", settings["image"], timeout=600)
        report["timingsSeconds"]["imageFetch"] = round(time.monotonic() - image_start, 3)
        phase = "cluster-setup"
        setup_start = time.monotonic()
        attempted_create = True
        phase = "container-create"
        d("create", "--name", name, "--label", f"{OWNER_LABEL}={token}", "--privileged", "--publish", "127.0.0.1::6443", settings["image"], "server", "--disable", "traefik", "--disable", "servicelb", "--disable", "metrics-server")
        phase = "container-start"
        d("start", name)
        phase = "api-readiness"
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
        phase = "api-version"
        version = json.loads(kubectl("get", "--raw=/version").stdout)
        if version["gitVersion"] != "v1.35.8+k3s1":
            raise ValueError("target-version-mismatch")
        phase = "api-endpoint"
        info = json.loads(d("inspect", name).stdout)[0]
        ports = info["NetworkSettings"]["Ports"]["6443/tcp"]
        if len(ports) != 1 or ports[0]["HostIp"] != "127.0.0.1":
            raise ValueError("nonlocal-api-endpoint")
        phase = "disposable-kubeconfig"
        config = yaml.safe_load(d("exec", name, "cat", "/etc/rancher/k3s/k3s.yaml").stdout)
        # Rebuild, do not merge with any ambient/default/production credentials.
        kubeconfig = work / "kubeconfig"
        config = {
            "apiVersion": "v1", "kind": "Config", "current-context": name,
            "clusters": [{"name": name, "cluster": {
                "server": f"https://127.0.0.1:{int(ports[0]['HostPort'])}",
                "certificate-authority-data": config["clusters"][0]["cluster"]["certificate-authority-data"],
            }}],
            "contexts": [{"name": name, "context": {"cluster": name, "user": name}}],
            "users": [{"name": name, "user": {
                key: config["users"][0]["user"][key]
                for key in ("client-certificate-data", "client-key-data")
            }}],
        }
        kubeconfig.write_text(yaml.safe_dump(config))
        kubeconfig.chmod(0o600)
        env["KUBECONFIG"] = str(kubeconfig)
        phase = "gateway-crd-input"
        crd = Path(settings["crd"]).read_text()
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
        phase = "gateway-crd-admission"
        kubectl("apply", "--server-side", "-f", "-", input=crd)
        phase = "gateway-crd-establishment"
        kubectl("wait", "--for=condition=Established", "--timeout=60s", "crd/gateways.gateway.networking.k8s.io", timeout=70)
        report["timingsSeconds"]["setup"] = round(time.monotonic() - setup_start, 3)
        phase = "chainsaw-scenario"
        scenario_start = time.monotonic()
        result = run([
            settings["chainsaw"], "test", str(args.test_dir.resolve()),
            "--kube-context", name, "--parallel", "1", "--repeat-count", "1",
            "--report-format", "JSON", "--report-path", str(work), "--report-name", "chainsaw",
            "--apply-timeout", "10s", "--assert-timeout", "10s", "--cleanup-timeout", "30s",
            "--exclude-test-regex", args.exclude_test_regex, "--selector", args.selector,
            "--no-color", "--remarshal",
        ], timeout=180, check=False)
        report["timingsSeconds"]["scenario"] = round(time.monotonic() - scenario_start, 3)
        phase = "scenario-report"
        raw = json.loads((work / "chainsaw.json").read_text())
        # Only retain fixed identity/status fields, not paths, namespace or error text.
        report["executed"] = [
            {"expectedIdentity": test.get("name") == SCENARIO, "status": test.get("status") if test.get("status") in ("passed", "failed", "skipped") else "unknown"}
            for test in raw.get("tests", [])
        ]
        report["operations"] = [
            {"index": index + 1, "type": operation.get("type"),
             "status": operation.get("status") if operation.get("status") in ("passed", "failed", "skipped") else "unknown"}
            for test in raw.get("tests", []) if test.get("name") == SCENARIO
            for step in test.get("steps", [])
            for index, operation in enumerate(step.get("operations", []))
        ]
        if result.returncode:
            namespaces = kubectl("get", "namespaces", "-o", "json", check=False)
            if namespaces.returncode == 0:
                report["terminatingNamespaceConditions"] = [
                    {key: condition.get(key) for key in ("type", "status", "reason")}
                    for namespace in json.loads(namespaces.stdout)["items"]
                    if namespace["metadata"].get("deletionTimestamp")
                    for condition in namespace.get("status", {}).get("conditions", [])
                ]
            apis = kubectl("get", "apiservices", "-o", "json", check=False)
            if apis.returncode == 0:
                report["unavailableAPIs"] = [
                    api["metadata"]["name"] for api in json.loads(apis.stdout)["items"]
                    if any(condition["type"] == "Available" and condition["status"] != "True"
                           for condition in api.get("status", {}).get("conditions", []))
                ]
        check_report(raw)
        if result.returncode:
            raise RuntimeError("chainsaw-exit-failure")
        report["status"] = "passed"
    except (Exception, KeyboardInterrupt) as error:
        report["failurePhase"] = phase
        report["failureReason"] = str(error) if isinstance(error, (ValueError, RuntimeError)) and str(error) in {
            "nonlocal-docker-transport", "command-failed", "interrupted", "readiness-timeout", "target-version-mismatch", "nonlocal-api-endpoint",
            "mutation-rule-missing-or-ambiguous", "mutation-v1-rule-missing", "scenario-coverage", "step-coverage", "operation-coverage", "unexpected-step", "scenario-failure-or-skip", "chainsaw-exit-failure",
        } else type(error).__name__
    finally:
        cleanup_start = time.monotonic()
        # A second signal must not interrupt removal of owned state.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            if attempted_create:
                info = d("inspect", name, check=False)
                if info.returncode == 0:
                    info = json.loads(info.stdout)[0]
                    if info["Config"]["Labels"].get(OWNER_LABEL) != token:
                        raise RuntimeError("ownership-mismatch")
                    volumes = [mount["Name"] for mount in info["Mounts"] if mount["Type"] == "volume"]
                    d("rm", "--force", "--volumes", name, timeout=60)
                    absent = d("inspect", name, check=False)
                    report["cleanup"]["container"] = absent.returncode != 0 and "no such" in absent.stderr.lower()
                    report["cleanup"]["volumes"] = all(
                        (result := d("volume", "inspect", volume, check=False)).returncode != 0 and "no such volume" in result.stderr.lower()
                        for volume in volumes
                    )
                elif "no such" not in info.stderr.lower():
                    raise RuntimeError("cleanup-inspect-failed")
        except Exception:
            report["cleanup"]["container"] = False
            report["cleanup"]["volumes"] = False
        try:
            temp.cleanup()
            report["cleanup"]["credentials"] = not work.exists()
        except Exception:
            report["cleanup"]["credentials"] = False
        if not all(report["cleanup"].values()):
            report.setdefault("failurePhase", "cleanup")
            report.setdefault("failureReason", "owned-state-cleanup-failed")
            report["status"] = "failed"
        report["timingsSeconds"]["cleanup"] = round(time.monotonic() - cleanup_start, 3)
        report["timingsSeconds"]["total"] = round(time.monotonic() - started, 3)
        json.dump(report, output, indent=2)
        output.write("\n")
        output.close()
        print(json.dumps(report, sort_keys=True))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
