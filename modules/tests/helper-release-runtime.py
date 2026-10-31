import base64
import json
import os
import re
import shlex
import time
from pathlib import Path
from typing import Any

registry = "publisher:5000"
namespace = "helper-release-proof"
root = "/srv/helper-release-proof"
receipt: dict[str, Any] = {"status": "not-completed", "limits": ["Disposable native x86-64 NixOS/K3s fixture, not live GHCR or Incus acceptance.", "A is the existing helper; B genuinely recompiles it with a test-only --version capability.", "Registry retains A/B for explicit rollback; no independent archive/offline-recovery promise."], "refusals": {}, "cleanup": {}}


def command(machine, text):
    return machine.succeed(text, timeout=180).strip()


def write_json(machine, path, value):
    command(machine, f"printf %s {shlex.quote(json.dumps(value))} > {shlex.quote(path)}")


def api(text):
    return command(cluster, f"{kubectl} {text}")


def observe():
    nodes = json.loads(api("get nodes -o json"))["items"]
    assert len(nodes) == 1
    return {"system": command(cluster, "readlink -f /run/current-system"), "bootID": command(cluster, "cat /proc/sys/kernel/random/boot_id"), "machineID": command(cluster, "cat /etc/machine-id"), "nodeUID": nodes[0]["metadata"]["uid"], "k3sPID": command(cluster, "systemctl show k3s -p MainPID --value")}


def listener():
    command(cluster, f"curl --fail --silent --cacert /run/helper-ca/ca.crt https://{registry}/v2/")
    api("get --raw=/readyz")


def release(letter):
    source = f"/run/helper-source-{letter}"
    command(publisher, f"cp -RL /etc/helper-source-{letter} {source}; chmod -R u+w {source}; git -C {source} init; git -C {source} add flake.nix; git -C {source} -c user.name=fixture -c user.email=fixture@example.invalid commit -m {letter}")
    source_sha = command(publisher, f"git -C {source} rev-parse HEAD")
    directory = f"/run/candidate-{letter}"
    common = f"--directory {directory} --source-sha {source_sha} --source-run {1 if letter == 'a' else 2} --system x86_64-linux --disposable"
    fingerprint = command(publisher, f"{tool} build {common} --source 'git+file://{source}?rev={source_sha}' --helpers retained-directories-image")
    assert re.fullmatch(r"[0-9a-f]{64}", fingerprint), fingerprint
    common += f" --candidate-sha256 {fingerprint}"
    command(publisher, f"REGISTRY_AUTH_FILE=/run/helper-auth.json {tool} publish {common} --prefix {registry}/homelab")
    publication = json.loads(command(publisher, f"cat {directory}/publication.json"))
    identity = publication["artifacts"]["retained-directories-image"]
    receipt[letter] = {"sourceSha": source_sha, "candidateSha256": fingerprint, **identity}
    return directory, common, publication


def refused(label, arguments, expected):
    before = command(publisher, "sha256sum /run/verified.json").split()[0]
    status, output = publisher.execute(f"{tool} {arguments} 2>&1", timeout=180)
    assert status != 0 and expected in output, (label, status, output)
    assert command(publisher, "sha256sum /run/verified.json").split()[0] == before
    listener()
    receipt["refusals"][label] = {"exitCode": status, "expectedErrorMatched": True, "selectionUnchanged": True, "positiveRegistryAndApiControls": True}


def job(name, image, args):
    manifest = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": name, "namespace": namespace}, "spec": {"backoffLimit": 0, "activeDeadlineSeconds": 180, "template": {"spec": {"restartPolicy": "Never", "automountServiceAccountToken": False, "containers": [{"name": "helper", "image": image, "imagePullPolicy": "Always", "args": args, "volumeMounts": [{"name": "state", "mountPath": "/state"}, {"name": "spec", "mountPath": "/spec", "readOnly": True}]}], "volumes": [{"name": "state", "hostPath": {"path": root, "type": "Directory"}}, {"name": "spec", "configMap": {"name": "retained-spec"}}]}}}}
    write_json(cluster, "/run/helper-job.json", manifest)
    api("apply -f /run/helper-job.json")


def state(name):
    items = json.loads(api(f"get pods -n {namespace} -l job-name={name} -o json"))["items"]
    statuses = items[0].get("status", {}).get("containerStatuses", []) if items else []
    return (items[0], statuses[0]) if statuses else (None, None)


def terminal(name, expected):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        pod, status = state(name)
        if status and "terminated" in status.get("state", {}):
            assert status["state"]["terminated"]["exitCode"] == expected, pod
            return {"exitCode": expected, "imageID": status["imageID"], "logs": api(f"logs -n {namespace} job/{name}")}
        time.sleep(1)
    raise AssertionError(f"Job {name} did not terminate")


def pull_refused(name, pattern):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        pod, status = state(name)
        if status:
            current = status.get("state", {})
            assert "running" not in current and "terminated" not in current, pod
            waiting = current.get("waiting", {})
            events = json.loads(api(f"get events -n {namespace} --field-selector involvedObject.name={pod['metadata']['name']} -o json"))
            messages = "\n".join(item.get("message", "") for item in events["items"])
            if waiting.get("reason") in ("ErrImagePull", "ImagePullBackOff") and re.search(pattern, messages, re.I):
                listener()
                receipt["refusals"][name] = {"containerNeverStarted": True, "reason": waiting["reason"], "positiveRegistryAndApiControls": True}
                return
        time.sleep(1)
    raise AssertionError(f"native pull refusal not observed for {name}")


def args_for(directory, marker=".retained-root"):
    return ["provision", "--spec", f"/spec/{marker}.json", "--entry", directory,
            "--confirm", f"fixture/{directory}"]


try:
    start_all()
    command(publisher, "install -d /run/helper-tls /etc/containers/certs.d/publisher:5000; openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=publisher -addext subjectAltName=DNS:publisher -addext basicConstraints=critical,CA:TRUE -keyout /run/helper-tls/server.key -out /run/helper-tls/server.crt; chown docker-registry:docker-registry /run/helper-tls/server.key; chmod 0600 /run/helper-tls/server.key; cp /run/helper-tls/server.crt /etc/containers/certs.d/publisher:5000/ca.crt; htpasswd -Bbn fixture synthetic-fixture-password > /run/helper-users")
    registry_config = {"version": 0.1, "storage": {"filesystem": {"rootdirectory": "/var/lib/docker-registry"}}, "http": {"addr": "0.0.0.0:5000", "tls": {"certificate": "/run/helper-tls/server.crt", "key": "/run/helper-tls/server.key"}}, "auth": {"htpasswd": {"realm": "fixture", "path": "/run/helper-users"}}}
    write_json(publisher, "/run/helper-registry.json", registry_config)
    credentials = base64.b64encode(b"fixture:synthetic-fixture-password").decode()
    write_json(publisher, "/run/helper-auth.json", {"auths": {registry: {"auth": credentials}}})
    command(publisher, "systemctl start docker-registry")
    publisher.wait_until_succeeds(f"curl --fail --silent --user fixture:synthetic-fixture-password --cacert /run/helper-tls/server.crt https://{registry}/v2/", timeout=60)
    ca = command(publisher, "cat /run/helper-tls/server.crt")
    command(cluster, f"install -d /run/helper-ca /etc/rancher/k3s {root}; printf '%s\n' {shlex.quote(ca)} > /run/helper-ca/ca.crt; mount -t tmpfs -o mode=0755,size=1m retained-helper {root}")
    write_json(cluster, "/etc/rancher/k3s/registries.yaml", {"mirrors": {registry: {"endpoint": [f"https://{registry}"]}}, "configs": {registry: {"tls": {"ca_file": "/run/helper-ca/ca.crt"}}}})
    command(cluster, "systemctl start k3s")
    cluster.wait_until_succeeds(f"{kubectl} get --raw=/readyz", timeout=300)
    cluster.wait_until_succeeds(f"{kubectl} wait --for=condition=Ready nodes --all --timeout=10s", timeout=180)
    receipt["before"] = observe()
    assert "retained-directories" not in command(cluster, f"{k3s} ctr --namespace k8s.io images ls -q")
    receipt["helperAbsentBeforePublication"] = True
    directory_a, common_a, publication_a = release("a")
    command(publisher, "printf 'selection-must-not-change\n' > /run/verified.json")
    status, output = publisher.execute(f"REGISTRY_AUTH_FILE=/run/helper-auth.json {tool} verify {common_a} --output /run/verified.json 2>&1", timeout=180)
    assert status != 0 and re.search("unauthorized|authentication required", output, re.I), output
    assert command(publisher, "cat /run/verified.json") == "selection-must-not-change"
    # This proves --no-creds wins even when publisher credentials are supplied.
    receipt["refusals"]["private-candidate"] = {"anonymousRefusedDespitePublisherCredentials": True, "selectionUnchanged": True}
    command(publisher, "systemctl stop docker-registry")
    del registry_config["auth"]
    write_json(publisher, "/run/helper-registry.json", registry_config)
    command(publisher, "systemctl start docker-registry")
    publisher.wait_until_succeeds(f"curl --fail --silent --cacert /run/helper-tls/server.crt https://{registry}/v2/", timeout=60)
    listener()
    command(publisher, f"{tool} verify {common_a} --output /run/verified.json")
    selected_a = json.loads(command(publisher, "cat /run/verified.json"))["artifacts"]["retained-directories-image"]
    image_a = f"{selected_a['repository']}@{selected_a['digest']}"
    api(f"create namespace {namespace}")
    spec = {"version": 1, "root": {"id": "fixture/root", "path": "/state", "marker": ".retained-root",
            "source": {"fsType": "tmpfs", "name": "retained-helper", "root": "/"},
            "uid": 0, "gid": 0, "mode": "0755"},
            "entries": {name: {"id": f"fixture/{name}", "uid": 1234, "gid": 2345, "mode": "0750"}
                        for name in ("a", "b", "rollback", "forbidden")}}
    wrong_spec = {**spec, "root": {**spec["root"], "marker": "missing-marker"}}
    write_json(cluster, "/run/helper-spec.json", spec)
    write_json(cluster, "/run/helper-wrong-spec.json", wrong_spec)
    api(f"create configmap retained-spec -n {namespace} --from-file=.retained-root.json=/run/helper-spec.json --from-file=missing-marker.json=/run/helper-wrong-spec.json")
    job("adopt-root", image_a, ["adopt", "--spec", "/spec/.retained-root.json", "--root", "--confirm", "fixture/root"])
    terminal("adopt-root", 0)
    job("a", image_a, args_for("a"))
    receipt["jobA"] = terminal("a", 0)
    assert json.loads(receipt["jobA"]["logs"])["id"] == "fixture/a"
    command(cluster, f"test $(stat -c '%u:%g:%a' {root}/a) = 1234:2345:750; printf usable-retained-state > {root}/a/payload")
    retained = command(cluster, f"stat -c '%d:%i:%u:%g:%a' {root}/a/payload")
    job("a-no-version", image_a, ["--version"])
    terminal("a-no-version", 64)
    directory_b, common_b, publication_b = release("b")
    command(publisher, f"{tool} verify {common_b} --output /run/verified.json")
    selected_b = json.loads(command(publisher, "cat /run/verified.json"))["artifacts"]["retained-directories-image"]
    image_b = f"{selected_b['repository']}@{selected_b['digest']}"
    assert selected_a["digest"] != selected_b["digest"] and selected_a["archiveSha256"] != selected_b["archiveSha256"] and selected_a["rootfs"] != selected_b["rootfs"]
    job("b-version", image_b, ["--version"])
    receipt["jobBVersion"] = terminal("b-version", 0)
    assert receipt["jobBVersion"]["logs"] == "fixture-v2"
    job("b", image_b, args_for("b"))
    receipt["jobB"] = terminal("b", 0)
    assert json.loads(receipt["jobB"]["logs"])["id"] == "fixture/b"
    command(cluster, f"test $(stat -c '%u:%g:%a' {root}/b) = 1234:2345:750; test $(cat {root}/a/payload) = usable-retained-state")
    assert command(cluster, f"stat -c '%d:%i:%u:%g:%a' {root}/a/payload") == retained
    receipt["retainedPayloadPreserved"] = True
    # Explicit rollback consumes the still-retained old registry identity.
    job("rollback-a", image_a, args_for("rollback"))
    receipt["rollbackA"] = terminal("rollback-a", 0)
    assert json.loads(receipt["rollbackA"]["logs"])["id"] == "fixture/rollback"
    job("wrong-marker", image_b, args_for("forbidden", "missing-marker"))
    terminal("wrong-marker", 1)
    command(cluster, f"test ! -e {root}/forbidden")
    receipt["refusals"]["wrong-marker"] = {"exitCode": 1, "directoryNotCreated": True}
    refused("wrong-source-sha", f"verify {common_a.replace(publication_a['sourceSha'], publication_b['sourceSha'])} --output /run/verified.json", "source SHA/run does not match")
    refused("unapproved-namespace", f"publish {common_a.replace('--disposable', '')} --prefix unauthorized.invalid/arbitrary", "unapproved publication namespace")
    refused("incomplete-production-inventory", f"publish {common_a.replace('--disposable', '')}", "fixed helper allowlist")
    command(publisher, f"printf altered >> {directory_a}/retained-directories-image.tar")
    refused("altered-archive", f"publish {common_a} --prefix {registry}/homelab", "altered transfer archive")
    command(publisher, f"truncate -s -7 {directory_a}/retained-directories-image.tar")
    original_candidate = json.loads(command(publisher, f"cat {directory_a}/candidate.json"))
    wrong_platform = dict(original_candidate, system="aarch64-linux")
    write_json(publisher, f"{directory_a}/candidate.json", wrong_platform)
    changed_hash = command(publisher, f"sha256sum {directory_a}/candidate.json").split()[0]
    wrong_common = common_a.replace("x86_64-linux", "aarch64-linux").replace(receipt["a"]["candidateSha256"], changed_hash)
    refused("wrong-native-platform", f"publish {wrong_common} --prefix {registry}/homelab", "artifact native platform mismatch")
    write_json(publisher, f"{directory_a}/candidate.json", original_candidate)
    # Restore canonical bytes; metadata mutation must also fail its independent fingerprint.
    restored_hash = command(publisher, f"sha256sum {directory_a}/candidate.json").split()[0]
    refused("altered-metadata", f"verify {common_a} --output /run/verified.json", "metadata differs from trusted read-only build")
    common_a = common_a.replace(receipt["a"]["candidateSha256"], restored_hash)
    mismatched = json.loads(json.dumps(publication_a))
    mismatched["artifacts"]["retained-directories-image"]["digest"] = selected_b["digest"]
    write_json(publisher, f"{directory_a}/publication.json", mismatched)
    refused("producer-mismatch", f"verify {common_a} --output /run/verified.json", "anonymous artifact differs from declared producer")
    missing = json.loads(json.dumps(publication_a))
    missing["artifacts"]["retained-directories-image"]["digest"] = "sha256:" + "0" * 64
    write_json(publisher, f"{directory_a}/publication.json", missing)
    refused("unavailable-digest", f"verify {common_a} --output /run/verified.json", "manifest unknown")
    missing["artifacts"]["retained-directories-image"]["digest"] = ""
    write_json(publisher, f"{directory_a}/publication.json", missing)
    refused("missing-digest", f"verify {common_a} --output /run/verified.json", "missing or invalid manifest digest")
    write_json(publisher, f"{directory_a}/publication.json", publication_a)
    command(publisher, "mv /etc/containers/certs.d/publisher:5000/ca.crt /run/helper-ca-untrusted.crt")
    refused("publisher-untrusted-tls", f"verify {common_a} --output /run/verified.json", "certificate")
    command(publisher, "mv /run/helper-ca-untrusted.crt /etc/containers/certs.d/publisher:5000/ca.crt")
    job("native-missing-digest", f"{selected_a['repository']}@sha256:{'0' * 64}", args_for("missing"))
    pull_refused("native-missing-digest", "not found|manifest unknown")
    address = command(cluster, "getent ahostsv4 publisher | cut -d ' ' -f 1 | sort -u")
    assert re.fullmatch(r"[0-9.]+", address), address
    job("native-untrusted-tls", image_a.replace("publisher", address), args_for("untrusted"))
    pull_refused("native-untrusted-tls", "certificate|x509")
    command(cluster, f"test ! -e {root}/missing; test ! -e {root}/untrusted")
    receipt["after"] = observe()
    assert receipt["before"] == receipt["after"]
    receipt["noHelperImportOrGuestRecreation"] = True
    receipt["status"] = "passed"
finally:
    if "before" in receipt:
        deleted, _ = cluster.execute(f"{kubectl} delete namespace {namespace} --ignore-not-found --wait=true --timeout=90s", timeout=120)
        removed, _ = cluster.execute(f"umount {root} && rm -rf {root} /run/helper-ca /run/helper-job.json")
        receipt["cleanup"]["clusterStateRemoved"] = removed == 0 and cluster.execute(f"test ! -e {root}")[0] == 0
        absent, diagnostic = cluster.execute(f"{kubectl} get namespace {namespace} 2>&1")
        ready, _ = cluster.execute(f"{kubectl} get --raw=/readyz")
        receipt["cleanup"]["jobsRemoved"] = deleted == 0 and absent != 0 and "NotFound" in diagnostic and ready == 0
    publisher.execute("systemctl stop docker-registry; rm -rf /var/lib/docker-registry /run/candidate-a /run/candidate-b /run/helper-source-a /run/helper-source-b /run/helper-tls /run/helper-auth.json /run/helper-users /run/helper-registry.json /run/verified.json /etc/containers/certs.d/publisher:5000")
    receipt["cleanup"]["registryAndTransferSourcesRemoved"] = publisher.execute("test ! -e /var/lib/docker-registry && test ! -e /run/helper-auth.json && test ! -e /run/candidate-a && test ! -e /run/candidate-b")[0] == 0
    receipt["cleanup"]["registryStopped"] = publisher.execute("test \"$(systemctl show docker-registry -p ActiveState --value)\" = inactive")[0] == 0
    Path(os.environ["out"], "helper-release-receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    assert all(receipt["cleanup"].values()), receipt["cleanup"]
