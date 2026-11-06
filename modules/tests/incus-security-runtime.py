import json
import shlex


IC = "timeout --kill-after=5s 60s incus"


def query(path):
    return json.loads(machine.succeed(f"{IC} query {shlex.quote(path)}"))


def identity():
    return machine.succeed(
        "openssl x509 -in /var/lib/incus/server.crt -noout -fingerprint -sha256"
    ).strip()


def resources():
    project = query("/1.0/projects/security-proof")
    profile = query("/1.0/profiles/security-proof")
    trust = query("/1.0/certificates?recursion=1")
    pool = query("/1.0/storage-pools/default")
    return {
        "project": project["config"]["user.probe"],
        "profile": profile["config"]["user.probe"],
        "pool": {"driver": pool["driver"], "source": pool["config"]["source"]},
        "trust": sorted((cert["fingerprint"], cert["name"], cert["restricted"])
                        for cert in trust),
    }


def https_status(certificate=None):
    credential = "" if certificate is None else (
        f"--cert /tmp/{certificate}.crt --key /tmp/{certificate}.key"
    )
    return machine.succeed(
        "curl --silent --show-error --connect-timeout 5 --max-time 10 "
        "--cacert /var/lib/incus/server.crt "
        f"{credential} --output /tmp/api-result.json --write-out '%{{http_code}}' "
        "https://127.0.0.1:8443/1.0/projects/security-proof"
    ).strip()


def authorization():
    assert https_status("trusted") == "200"
    response = json.loads(machine.succeed("cat /tmp/api-result.json"))
    assert response["metadata"]["config"]["user.probe"] == "retained-project"
    assert https_status() == "403"
    assert https_status("untrusted") == "403"


def instance_data():
    machine.succeed(f"{IC} start proof")
    assert machine.succeed(f"{IC} exec proof --disable-stdin -- cat /marker") == "retained-instance-data"
    machine.succeed(f"{IC} stop proof --force")


def stop_daemon():
    machine.succeed("systemctl stop incus.socket incus.service")
    assert machine.succeed(
        "systemctl show incus.service --property=ActiveState --value"
    ).strip() == "inactive"
    assert machine.succeed(
        "systemctl show incus.service --property=MainPID --value"
    ).strip() == "0"


def start_daemon(expected):
    machine.succeed("systemctl start incus.socket incus.service")
    machine.wait_for_unit("incus.service", timeout=90)
    machine.wait_until_succeeds(f"{IC} query /1.0", timeout=90)
    machine.wait_for_open_port(8443, timeout=60)
    version = query("/1.0")["environment"]["server_version"]
    client = machine.succeed(f"{IC} --version").strip()
    pid = int(machine.succeed("systemctl show incus.service --property=MainPID --value"))
    executable = machine.succeed(f"readlink -f /proc/{pid}/exe").strip()
    client_executable = machine.succeed("readlink -f $(command -v incus)").strip()
    environment = shlex.split(machine.succeed(
        "systemctl show incus.service --property=Environment --value"
    ))
    machine.log(
        f"Incus daemon={version} (package {expected['package_version']}) "
        f"client={client} (package {expected['client_package_version']}) "
        f"executable={executable} client_executable={client_executable}"
    )
    assert version == expected["daemon_version"], (version, expected)
    assert client == expected["client_version"], (client, expected)
    assert executable == expected["package"] + "/bin/incusd", (executable, expected)
    assert client_executable == expected["client"] + "/bin/incus", (client_executable, expected)
    assert "INCUS_UI=" + expected["ui"] in environment, environment


start_all()
machine.wait_for_unit("incus-preseed.service", timeout=120)
assert baseline["daemon_version"] == baseline["client_version"] == "7.4"
assert candidate["daemon_version"] == candidate["client_version"] == "7.6"
assert baseline["package"] != candidate["package"]
start_daemon(baseline)
baseline_system = machine.succeed("readlink -f /run/current-system").strip()

with subtest("stock 7.4 daemon retains real resources and accepts only a trusted client"):
    machine.succeed(
        f"{IC} project create security-proof -c user.probe=retained-project",
        f"{IC} profile create security-proof",
        f"{IC} profile set security-proof user.probe=retained-profile",
    )
    for name in ["trusted", "untrusted"]:
        machine.succeed(
            "openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 "
            f"-keyout /tmp/{name}.key -out /tmp/{name}.crt -subj /CN={name}"
        )
    machine.succeed(f"{IC} config trust add-certificate /tmp/trusted.crt --name security-proof")
    authorization()
    machine.succeed(
        f"{IC} image import {image} --alias busybox",
        f"{IC} init busybox proof",
        f"{IC} config set proof boot.autostart=false",
        f"{IC} start proof",
        f"{IC} exec proof --disable-stdin -- /bin/sh -c 'printf retained-instance-data > /marker'",
        f"{IC} stop proof --force",
    )
    server_identity = identity()
    expected_resources = resources()
    assert expected_resources["project"] == "retained-project"
    assert expected_resources["profile"] == "retained-profile"
    assert expected_resources["pool"] == {
        "driver": "dir", "source": "/var/lib/incus-storage-pools/fixture"
    }
    assert [row[1:] for row in expected_resources["trust"]] == [("security-proof", False)]
    instance_data()

with subtest("clean stock 7.4 daemon stop and full state plus external dir-pool cold backup"):
    assert query("/1.0/instances/proof")["status"] == "Stopped"
    stop_daemon()
    machine.succeed(
        "tar --xattrs --acls --numeric-owner -C /var/lib -cpf /tmp/incus-old-cold.tar incus incus-storage-pools"
    )

with subtest("production-selected 7.6 daemon and client keep identity trust and instance data"):
    machine.succeed(f"{baseline_system}/specialisation/security-update/bin/switch-to-configuration test")
    start_daemon(candidate)
    assert identity() == server_identity
    assert resources() == expected_resources
    authorization()
    instance_data()

with subtest("cold-start restored stock 7.4 state recovers identity authorization and data"):
    assert query("/1.0/instances/proof")["status"] == "Stopped"
    stop_daemon()
    machine.succeed(
        "rm -rf /var/lib/incus /var/lib/incus-storage-pools",
        "tar --xattrs --acls --numeric-owner -C /var/lib -xpf /tmp/incus-old-cold.tar",
        f"{baseline_system}/bin/switch-to-configuration test",
    )
    start_daemon(baseline)
    assert identity() == server_identity
    assert resources() == expected_resources
    authorization()
    instance_data()

# Stopped full-state and external dir-pool restore followed by an old-daemon
# cold start only: not an in-place schema downgrade or physical reboot, ZFS/LVM,
# running-volume backup, or production activation proof. No live host is changed.
# Normal trusted/untrusted HTTPS clients are exercised; no forged-chain exploit,
# cluster-gateway regression, or compiler/SDK/dependency security fix is proved.
