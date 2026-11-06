import json
import os
import shlex


data_dir = "/persist/crowdsec/data"
credential = f"{data_dir}/local_api_credentials.yaml"
console_path = f"{data_dir}/console.yaml"
bouncer_key = "/var/lib/crowdsec-firewall-bouncer-register/api-key.cred"
attacker_ip = "192.168.1.20"
new_state_ip = "198.51.100.77"
probe = (
    "curl --fail --silent --show-error --noproxy '*' --connect-timeout 2 "
    "--max-time 3 -H 'Connection: close' http://192.168.1.10:8088/ "
    "| grep -Fx crowdsec-protected"
)
# A pipeline must not hide a curl failure behind a successful consumer.
probe = "bash -o pipefail -c " + shlex.quote(probe)


def digest(path):
    return fixture.succeed("sha256sum " + shlex.quote(path)).split()[0]


def read_yaml(path):
    code = "import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))"
    return json.loads(fixture.succeed("python3 -c " + shlex.quote(code) + " " + shlex.quote(path)))


def machine_registrations():
    records = json.loads(fixture.succeed("cscli machines list --output json"))
    # Exclude heartbeat/version timestamps, not identity or validation state.
    return [{key: record[key] for key in ("machineId", "created_at", "isValidated", "auth_type")} for record in records]


def decisions():
    alerts = json.loads(fixture.succeed("cscli decisions list --output json"))
    return {decision["value"] for alert in alerts for decision in alert["decisions"]}


def ready(version, system):
    fixture.wait_for_unit("multi-user.target")
    fixture.wait_for_unit("crowdsec.service")
    fixture.wait_for_unit("crowdsec-firewall-bouncer.service")
    assert fixture.succeed("readlink -f /run/current-system").strip() == system
    assert f"v{version}" in fixture.succeed("cscli version 2>&1")
    executable = fixture.succeed('readlink -f /proc/$(systemctl show --value -p MainPID crowdsec.service)/exe')
    assert f"crowdsec-{version}/" in executable, executable
    assert fixture.succeed("id -u crowdsec").strip() == "661"
    assert fixture.succeed("id -g crowdsec").strip() == "661"
    assert fixture.succeed("findmnt -nro FSTYPE --mountpoint /").strip() == "tmpfs"
    assert fixture.succeed("findmnt -nro FSTYPE --mountpoint /persist").strip() == "ext4"
    fixture.succeed(f"test ! -e {data_dir}/online_api_credentials.yaml")
    assert "You can successfully interact with Local API (LAPI)" in fixture.succeed("cscli lapi status")


def authenticated_bouncer():
    records = json.loads(fixture.succeed("cscli bouncers list --output json"))
    assert len(records) == 1 and records[0]["name"] == "crowdsec-firewall-bouncer", records
    # Check the retained/generated key against LAPI, not merely a backend set.
    response = fixture.succeed(
        'curl --fail --silent --show-error --noproxy "*" '
        f'-H "X-Api-Key:$(cat {bouncer_key})" '
        f"'http://127.0.0.1:8080/v1/decisions?ip={attacker_ip}'"
    )
    assert any(item["value"] == attacker_ip for item in json.loads(response)), response


def blocked():
    # Every curl is a new TCP flow. Control shares the same server/port and is
    # never banned; driver recovery is the independent virtio console, not IP.
    control.wait_until_succeeds(probe, timeout=60)
    attacker.wait_until_fails(probe, timeout=60)
    for _ in range(3):
        control.succeed(probe)
        attacker.fail(probe)
    assert attacker_ip in fixture.succeed("nft list ruleset")
    authenticated_bouncer()


def retained(expected_decisions):
    assert digest(credential) == original_credentials
    assert machine_registrations() == original_machines
    assert read_yaml(console_path) == operator_console, "console sharing was overwritten by generated defaults"
    assert expected_decisions <= decisions()
    blocked()


def generated_new_config():
    marker = "fixture-new-%H-%m-%%"
    profiles = fixture.succeed("cat /etc/crowdsec/profiles.yaml")
    acquisitions = fixture.succeed("cat /etc/crowdsec/acquis.d/0-nixos-generated.yaml")
    assert marker in profiles and "fixture-old" not in profiles, profiles
    assert marker in acquisitions and "fixture-old" not in acquisitions, acquisitions


def restart_services():
    fixture.succeed("systemctl restart crowdsec-setup.service crowdsec.service")
    fixture.wait_for_unit("crowdsec.service")
    fixture.succeed("systemctl restart crowdsec-firewall-bouncer-register.service crowdsec-firewall-bouncer.service")
    fixture.wait_for_unit("crowdsec-firewall-bouncer.service")


def cold_boot(system, version):
    fixture.succeed("touch /root/ephemeral-marker; sync")
    previous_key = digest(bouncer_key)
    fixture.shutdown()
    # Native qemu-vm direct boot appends QEMU_KERNEL_PARAMS. Stage 1 chooses
    # the last init=; the kernel/initrd/root pkgs are identical in both systems.
    # Select the actual generation at boot, not an activation after old boot.
    previous_params = os.environ.get("QEMU_KERNEL_PARAMS")
    os.environ["QEMU_KERNEL_PARAMS"] = (previous_params or "") + f" init={system}/init"
    try:
        fixture.start()
    finally:
        if previous_params is None:
            os.environ.pop("QEMU_KERNEL_PARAMS", None)
        else:
            os.environ["QEMU_KERNEL_PARAMS"] = previous_params
    ready(version, system)
    fixture.succeed("test ! -e /root/ephemeral-marker")
    # No new key-persistence promise: upstream must replace the missing key,
    # reconcile the existing DB registration, and authenticate exactly once.
    assert digest(bouncer_key) != previous_key
    registration_log = fixture.succeed("journalctl --boot -u crowdsec-firewall-bouncer-register.service --no-pager")
    assert "Bouncer registered but API key is not present" in registration_log, registration_log


start_all()
old_system = fixture.succeed("readlink -f /run/current-system").strip()
new_system = fixture.succeed(f"readlink -f {old_system}/specialisation/upgraded").strip()

with subtest("old 1.8.0 setup, real LAPI and packet enforcement"):
    ready("1.8.0", old_system)
    attacker.wait_until_succeeds(probe)
    control.wait_until_succeeds(probe)
    assert read_yaml(console_path) == {
        "share_manual_decisions": False,
        "share_custom": False,
        "share_tainted": False,
        "share_context": False,
    }
    # cscli console commands require CAPI credentials even for local changes.
    # Make an operator's valid local edit without inventing a remote identity.
    operator_console = {
        "share_manual_decisions": True,
        "share_custom": True,
        "share_tainted": False,
        "share_context": True,
    }
    edit = (
        "import sys,yaml; "
        "p=sys.argv[1]; "
        f"yaml.safe_dump({operator_console!r},open(p,'w'))"
    )
    fixture.succeed("python3 -c " + shlex.quote(edit) + " " + shlex.quote(console_path))
    original_credentials = digest(credential)
    original_machines = machine_registrations()
    assert len(original_machines) == 1 and original_machines[0]["machineId"] == "crowdsec-fixture"
    assert original_machines[0]["isValidated"] is True
    original_key = digest(bouncer_key)
    fixture.succeed(f"cscli decisions add --ip {attacker_ip} --duration 12h")
    retained({attacker_ip})

with subtest("consistent stopped-service pre-upgrade snapshot, not a rollback shortcut"):
    fixture.succeed("systemctl stop crowdsec-firewall-bouncer.service crowdsec-firewall-bouncer-register.service crowdsec.service crowdsec-setup.service")
    assert fixture.succeed(f"sqlite3 {data_dir}/crowdsec.db 'PRAGMA integrity_check'").strip() == "ok"
    # Copy whole directories while all writers are stopped, including any WAL,
    # credentials, mutable hub, console state, and the otherwise ephemeral key.
    fixture.succeed("tar -C / -cpf /persist/pre-upgrade.tar persist/crowdsec var/lib/crowdsec-firewall-bouncer-register")
    snapshot_hash = digest("/persist/pre-upgrade.tar")
    snapshot_members = fixture.succeed("tar -tf /persist/pre-upgrade.tar")
    assert "persist/crowdsec/data/crowdsec.db" in snapshot_members
    assert "persist/crowdsec/data/local_api_credentials.yaml" in snapshot_members
    assert "var/lib/crowdsec-firewall-bouncer-register/api-key.cred" in snapshot_members
    fixture.succeed("systemctl start crowdsec.service crowdsec-firewall-bouncer.service")
    retained({attacker_ip})

with subtest("live activation of real new aspect/modules and 1.8.1"):
    fixture.succeed("touch /root/ephemeral-marker")
    fixture.succeed(f"{new_system}/bin/switch-to-configuration test")
    # Ensure the new tmpfiles operation actually executes; restarting only
    # CrowdSec would miss the console f+ regression this check protects.
    fixture.succeed(f"systemd-tmpfiles --create --prefix={console_path}")
    ready("1.8.1", new_system)
    retained({attacker_ip})
    generated_new_config()
    fixture.succeed("test -e /root/ephemeral-marker")
    assert digest(bouncer_key) == original_key
    restart_services()
    ready("1.8.1", new_system)
    retained({attacker_ip})
    assert digest(bouncer_key) == original_key
    # This state did not exist in the snapshot: old executables must consume
    # it after both live rollback and cold boot, with no restore in between.
    fixture.succeed(f"cscli decisions add --ip {new_state_ip} --duration 12h")
    retained({attacker_ip, new_state_ip})

with subtest("cold new generation, empty root, retained persist, native key recovery"):
    cold_boot(new_system, "1.8.1")
    retained({attacker_ip, new_state_ip})
    generated_new_config()
    cold_new_key = digest(bouncer_key)
    restart_services()
    retained({attacker_ip, new_state_ip})
    assert digest(bouncer_key) == cold_new_key

with subtest("in-place old executable rollback consumes new-touched state"):
    fixture.succeed(f"{old_system}/bin/switch-to-configuration test")
    fixture.succeed(f"systemd-tmpfiles --create --prefix={console_path}")
    ready("1.8.0", old_system)
    retained({attacker_ip, new_state_ip})
    assert digest(bouncer_key) == cold_new_key
    restart_services()
    retained({attacker_ip, new_state_ip})
    assert digest(bouncer_key) == cold_new_key

with subtest("cold old generation reads upgraded database and unban restores access"):
    cold_boot(old_system, "1.8.0")
    retained({attacker_ip, new_state_ip})
    assert "fixture-old" in fixture.succeed("cat /etc/crowdsec/profiles.yaml")
    fixture.succeed(f"cscli decisions delete --ip {attacker_ip}")
    attacker.wait_until_succeeds(probe, timeout=60)
    control.succeed(probe)
    assert attacker_ip not in decisions()
    assert new_state_ip in decisions()
    # A fresh write with the old binary also succeeds against upgraded state.
    fixture.succeed(f"cscli decisions delete --ip {new_state_ip}")
    assert new_state_ip not in decisions()
    assert digest("/persist/pre-upgrade.tar") == snapshot_hash
    assert machine_registrations() == original_machines
    assert digest(credential) == original_credentials
    assert read_yaml(console_path) == operator_console
    print("CROWDSEC_LIVE_UPGRADE_EPHEMERAL_COLD_BOOT_AND_IN_PLACE_ROLLBACK_PRESERVED_STATE_AND_ENFORCEMENT")
