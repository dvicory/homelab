"""Run inside the coordinator's disposable native NixOS K3s API test VM."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import uuid


ROOT = Path("/srv/secrets")
STATE = Path("/var/lib/homelab-runtime-secrets")
CASES = [
    "initial-exact-ack", "missing-desired-inventory", "stale-desired-inventory",
    "malformed-desired-inventory", "malformed-owned-inventory", "duplicate-owned-inventory",
    "failed-uid-recording-keeps-ack", "ssa-foreign-keys-and-replacement-uid",
    "empty-generation-relinquishes-only-owned-fields",
]


class Failure(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Failure(reason)


def main():
    settings = json.loads(Path(sys.argv[1]).read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, help="Owned NixOS test VM identity, set by coordinator")
    args = parser.parse_args(sys.argv[2:])
    report = {
        "scenario": "runtime-secret-ssa-uid", "status": "failed", "cases": [],
        "provenance": settings["provenance"], "scriptSha256": settings["scriptSha256"],
        "system": settings["system"],
        "deployedSystem": settings["deployedSystem"],
        "nativePlatformOverride": settings["nativePlatformOverride"],
    }
    phase = "fixture-boundary"
    env = {key: value for key, value in os.environ.items() if key not in ("KUBECONFIG", "KUBERNETES_MASTER")}

    def run(command, *, input=None, check=True):
        result = subprocess.run(command, env=env, input=input, text=True, capture_output=True, timeout=60)
        if check:
            require(result.returncode == 0, "command-failed")
        return result

    def kubectl(*command, **options):
        return run([settings["kubectl"], "kubectl", "--kubeconfig", "/etc/rancher/k3s/k3s.yaml",
                    "--context", "default", "--request-timeout=10s", *command], **options)

    def secret(name, data, type_name="Opaque"):
        return {
            "apiVersion": "v1", "kind": "Secret",
            "metadata": {"namespace": namespace, "name": name,
                         "labels": {"homelab.danielvicory/runtime-secret": "true"}},
            "type": type_name,
            "data": {key: base64.b64encode(value.encode()).decode() for key, value in data.items()},
        }

    def apply(resource, manager):
        kubectl("apply", "--server-side", "--force-conflicts", "--field-manager", manager,
                "-f", "-", input=json.dumps(resource))

    def get(name):
        return json.loads(kubectl("get", "secret", name, "-n", namespace, "-o", "json").stdout)

    def snapshots():
        objects = json.loads(kubectl("get", "secrets", "-n", namespace, "-o", "json").stdout)["items"]
        files = {str(path.relative_to(STATE)): path.read_bytes() for path in STATE.rglob("*") if path.is_file()}
        return sorted(objects, key=lambda item: item["metadata"]["name"]), files

    def stage(resources, names=None):
        # JSON is valid YAML, accepted by the actual kubectl invoked by the script.
        yaml = "\n---\n".join(json.dumps(resource, sort_keys=True) for resource in resources)
        yaml_bytes = (yaml + "\n").encode() if yaml else b""
        if names is None:
            names = "".join(sorted(
                f"{namespace}\t{item['metadata']['name']}\t{item['type']}\t{','.join(sorted(item['data']))}\n"
                for item in resources
            ))
        names_bytes = names.encode()
        yaml_hash = hashlib.sha256(yaml_bytes).hexdigest()
        names_hash = hashlib.sha256(names_bytes).hexdigest()
        generation = hashlib.sha256(f"{yaml_hash}\n{names_hash}\n".encode()).hexdigest()
        (ROOT / "runtime-secrets.yaml").write_bytes(yaml_bytes)
        (ROOT / "runtime-secrets.names").write_bytes(names_bytes)
        # Publish the commitment last, just like the producer's delivery boundary.
        (ROOT / "runtime-secrets.commit").write_text(
            f"generation={generation} yaml-sha256={yaml_hash} names-sha256={names_hash}\n")
        return generation

    def reconcile():
        return run([settings["script"]], check=False)

    def acknowledged(generation):
        path = STATE / "applied-generation"
        return path.exists() and path.read_bytes() == (generation + "\n").encode()

    def refused_without_mutation(case):
        nonlocal phase
        phase = case
        before = snapshots()
        require(reconcile().returncode != 0, "invalid-generation-accepted")
        require(snapshots() == before, "refusal-mutated-api-or-state")
        report["cases"].append({"name": case, "status": "passed"})

    try:
        require(sys.platform == "linux" and os.geteuid() == 0, "not-owned-linux-fixture")
        require(run([settings["virtualizationProbe"], "--vm"], check=False).returncode == 0,
                "not-virtual-machine")
        require(os.environ.get("HOMELAB_RUNTIME_SECRET_FIXTURE") == args.fixture,
                "fixture-ownership-not-supplied")
        expected_arch = {"x86_64-linux": "x86_64", "aarch64-linux": "aarch64"}[settings["system"]]
        require(platform.machine() == expected_arch, "fixture-architecture-mismatch")
        require(not ROOT.exists() and not STATE.exists(), "fixture-state-already-exists")
        version = json.loads(kubectl("version", "-o", "json").stdout)
        require(version["clientVersion"]["gitVersion"] == version["serverVersion"]["gitVersion"],
                "client-server-version-mismatch")
        ROOT.mkdir(parents=True, mode=0o700)
        STATE.mkdir(parents=True, mode=0o700)
        namespace = "runtime-secret-api-" + uuid.uuid4().hex[:16]
        kubectl("create", "namespace", namespace)

        phase = "initial-exact-ack"
        initial = [secret("shared", {"source-one": "one", "source-two": "two"}),
                   secret("replaced", {"tls.crt": "synthetic-crt", "tls.key": "synthetic-key"}, "kubernetes.io/tls")]
        initial_generation = stage(initial)
        initial_names = (ROOT / "runtime-secrets.names").read_bytes()
        require(not acknowledged(initial_generation), "missing-ack-accepted")
        require(reconcile().returncode == 0, "initial-reconciliation-failed")
        require(acknowledged(initial_generation), "successful-generation-not-acknowledged")
        shared_uid = get("shared")["metadata"]["uid"]
        old_uid = get("replaced")["metadata"]["uid"]
        owned = (STATE / "owned").read_bytes()
        require(sorted(line.split("\t") for line in owned.decode().splitlines())
                == [[namespace, "replaced", old_uid], [namespace, "shared", shared_uid]],
                "initial-ownership-not-recorded")
        report["cases"].append({"name": phase, "status": "passed"})

        apply(secret("shared", {"application": "foreign-value"}), "application")
        apply(secret("forged", {"foreign": "label-does-not-confer-ownership"}), "application")
        forged = get("forged")
        kubectl("delete", "secret", "replaced", "-n", namespace)
        apply(secret("replaced", {"tls.crt": "replacement-crt", "tls.key": "replacement-key"}, "kubernetes.io/tls"), "application")
        replacement = get("replaced")
        require(replacement["metadata"]["uid"] != old_uid, "replacement-uid-not-distinct")
        desired = [secret("shared", {"source-one": "updated"})]

        stage(desired)
        (ROOT / "runtime-secrets.names").unlink()
        refused_without_mutation("missing-desired-inventory")
        stage(desired)
        (ROOT / "runtime-secrets.names").write_bytes(initial_names)
        refused_without_mutation("stale-desired-inventory")
        stage(desired, f"{namespace}\tshared\tOpaque\tmalformed key\n")
        refused_without_mutation("malformed-desired-inventory")
        stage(desired)
        (STATE / "owned").write_bytes(b"malformed\tinventory\n")
        refused_without_mutation("malformed-owned-inventory")
        (STATE / "owned").write_bytes(owned + owned)
        refused_without_mutation("duplicate-owned-inventory")
        (STATE / "owned").write_bytes(owned)

        phase = "failed-uid-recording-keeps-ack"
        # Apply really succeeds, then UID recording fails on a declared but absent
        # Secret. This proves ack safety after an API mutation, not just preflight.
        failed_generation = stage(desired, f"{namespace}\tghost\tOpaque\tkey\n{namespace}\tshared\tOpaque\tsource-one\n")
        require(not acknowledged(failed_generation), "stale-ack-accepted")
        require(reconcile().returncode != 0, "missing-secret-recording-accepted")
        require(get("shared")["data"]["source-one"] == desired[0]["data"]["source-one"],
                "post-apply-failure-not-exercised")
        require(acknowledged(initial_generation) and not acknowledged(failed_generation), "failed-generation-advanced-ack")
        require((STATE / "owned").read_bytes() == owned, "failed-recording-changed-owned-inventory")
        require(not any(path.name != "owned" and path.name != "applied-generation" for path in STATE.iterdir()),
                "failed-recording-left-temporary-state")
        report["cases"].append({"name": phase, "status": "passed"})

        phase = "ssa-foreign-keys-and-replacement-uid"
        generation = stage(desired)
        require(not acknowledged(generation), "stale-ack-accepted")
        require(reconcile().returncode == 0, "ssa-reconciliation-failed")
        shared = get("shared")
        require(shared["metadata"]["uid"] == shared_uid and shared["type"] == "Opaque"
                and shared["data"] == {"source-one": desired[0]["data"]["source-one"],
                                       "application": base64.b64encode(b"foreign-value").decode()},
                "ssa-did-not-preserve-foreign-or-remove-owned-key")
        require(get("replaced") == replacement, "replacement-object-mutated")
        require(get("forged") == forged, "unowned-labeled-object-mutated")
        require((STATE / "owned").read_bytes() == f"{namespace}\tshared\t{shared_uid}\n".encode(),
                "retired-uid-still-owned")
        require(acknowledged(generation), "successful-generation-not-acknowledged")
        report["cases"].append({"name": phase, "status": "passed"})

        phase = "empty-generation-relinquishes-only-owned-fields"
        empty_generation = stage([])
        require(not acknowledged(empty_generation), "stale-ack-accepted")
        require(reconcile().returncode == 0, "empty-reconciliation-failed")
        shared = get("shared")
        require(shared["metadata"]["uid"] == shared_uid
                and shared["data"] == {"application": base64.b64encode(b"foreign-value").decode()},
                "retirement-did-not-preserve-foreign-key")
        require(get("replaced") == replacement and get("forged") == forged, "retirement-mutated-unowned-object")
        require((STATE / "owned").read_bytes() == b"" and acknowledged(empty_generation), "empty-generation-not-acknowledged")
        report["cases"].append({"name": phase, "status": "passed"})
        require([case["name"] for case in report["cases"]] == CASES, "missing-case-coverage")
        report["status"] = "passed"
    except Exception as error:
        report["failurePhase"] = phase
        # Never include command output, credentials, resource data or traceback.
        report["failureReason"] = str(error) if isinstance(error, Failure) else type(error).__name__
    print(json.dumps(report, sort_keys=True))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
