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


def start_daemon():
    machine.succeed("systemctl start incus.socket incus.service")
    machine.wait_for_unit("incus.service", timeout=90)
    machine.wait_until_succeeds(f"{IC} query /1.0", timeout=90)
    machine.wait_for_open_port(8443, timeout=60)
    version = query("/1.0")["environment"]["server_version"]
    client = machine.succeed(f"{IC} --version").strip()
    machine.log(f"Incus daemon={version} client={client}")


start_all()
machine.wait_for_unit("incus-preseed.service", timeout=120)
start_daemon()
baseline_system = machine.succeed("readlink -f /run/current-system").strip()

with subtest("old daemon retains real resources and accepts only a trusted client"):
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
    assert [row[1:] for row in expected_resources["trust"]] == [("security-proof", False)]

with subtest("clean old daemon stop and full state plus external dir-pool cold backup"):
    stop_daemon()
    machine.succeed(
        "tar --xattrs --acls --numeric-owner -C /var/lib -cpf /tmp/incus-old-cold.tar incus incus-storage-pools"
    )

with subtest("supported daemon keeps server identity trust and instance data"):
    machine.succeed(f"{baseline_system}/specialisation/security-update/bin/switch-to-configuration test")
    start_daemon()
    pid = int(machine.succeed("systemctl show incus.service --property=MainPID --value"))
    assert machine.succeed(f"readlink -f /proc/{pid}/exe").strip().startswith(selected_package + "/bin/")
    assert identity() == server_identity
    assert resources() == expected_resources
    authorization()
    instance_data()

with subtest("stopped cold restore recovers old daemon identity authorization and data"):
    stop_daemon()
    machine.succeed(
        "rm -rf /var/lib/incus /var/lib/incus-storage-pools",
        "tar --xattrs --acls --numeric-owner -C /var/lib -xpf /tmp/incus-old-cold.tar",
        f"{baseline_system}/bin/switch-to-configuration test",
    )
    start_daemon()
    assert identity() == server_identity
    assert resources() == expected_resources
    authorization()
    instance_data()

# External dir-pool cold restore only: not ZFS/LVM, running-volume backup,
# direct old-on-new database compatibility, or production activation proof.
# Normal trusted/untrusted HTTPS clients are exercised; no forged-chain
# exploit or cluster-gateway regression is claimed by this fixture.
