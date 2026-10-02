"""Owned pinned K3s, real controllers/protocols and required Chainsaw safety scenarios."""

import argparse
import ipaddress
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
from report import REQUIRED_SCENARIOS, check_report

OWNER_LABEL = "verification.homelab/fixture"


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
    transport_ready = False
    network_attempted = False

    def run(command, *, timeout=60, check=True, input=None):
        result = subprocess.run(command, env=env, cwd=work, input=input, text=True, capture_output=True, timeout=timeout)
        if check and result.returncode:
            report["commandFailure"] = {"program": Path(command[0]).name, "returnCode": result.returncode}
            raise RuntimeError("command-failed")
        return result

    def d(*command, **options):
        return run(docker + list(command), **options)

    def kubectl(*command, **options):
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
            "KUBECTL": settings["kubectlWrapper"], "PATH": settings["path"] + os.pathsep + env.get("PATH", ""),
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
            d("save", "--output", str(archive), image, timeout=600)
            registry_archives.append(archive)
        report["timingsSeconds"]["imageFetch"] = round(time.monotonic() - image_start, 3)
        phase = "cluster-setup"
        setup_start = time.monotonic()
        network_attempted = True
        d("network", "create", "--label", f"{OWNER_LABEL}={token}", network)
        net = json.loads(d("network", "inspect", network).stdout)[0]
        subnet = ipaddress.ip_network(net["IPAM"]["Config"][0]["Subnet"])
        def address(offset):
            return str(subnet.network_address + offset)
        env.update({"FIXTURE_NODE_IP": address(10), "FIXTURE_TRUSTED_IP": address(11), "FIXTURE_STRANGER_IP": address(20)})
        create_container(name, settings["image"], ["server", "--node-name", "compute-1", "--disable", "traefik", "--disable", "servicelb", "--disable", "metrics-server", "--disable", "local-storage"], address(10), privileged=True, publish=True)
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
        native_failed = False
        for index, directory in enumerate(directories):
            # Explicit native invocations preserve suite dependencies; Chainsaw
            # only guarantees step order within a Test, not discovery order.
            report_name = f"chainsaw-{index}"
            remaining = 3600 - (time.monotonic() - scenario_start)
            if remaining <= 0:
                raise RuntimeError("scenario-deadline")
            result = run([
                settings["chainsaw"], "test", directory,
                "--kube-context", name, "--parallel", "1", "--repeat-count", "1",
                "--report-format", "JSON", "--report-path", str(work), "--report-name", report_name,
                "--apply-timeout", "60s", "--assert-timeout", "180s", "--cleanup-timeout", "60s",
                "--exec-timeout", "600s", "--delete-timeout", "60s", "--kube-request-timeout", "30s",
                "--exclude-test-regex", args.exclude_test_regex, "--selector", args.selector,
                "--no-color", "--remarshal",
            ], timeout=remaining, check=False)
            native_failed |= result.returncode != 0
            phase = "scenario-report"
            chunk = json.loads((work / f"{report_name}.json").read_text())
            raw["tests"].extend(chunk.get("tests") or [])
            phase = "chainsaw-scenarios"
        report["timingsSeconds"]["scenario"] = round(time.monotonic() - scenario_start, 3)
        phase = "scenario-report"
        report["executed"] = [{"name": test.get("name") if test.get("name") in required else "unexpected", "status": test.get("status") if test.get("status") in ("passed", "failed", "skipped") else "unknown"} for test in raw.get("tests", [])]
        check_report(raw, required)
        if native_failed:
            raise RuntimeError("chainsaw-exit-failure")
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
    finally:
        cleanup_start = time.monotonic()
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
        report["timingsSeconds"]["cleanup"] = round(time.monotonic() - cleanup_start, 3)
        report["timingsSeconds"]["total"] = round(time.monotonic() - started, 3)
        json.dump(report, output, indent=2)
        output.write("\n")
        output.close()
        print(json.dumps(report, sort_keys=True))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
