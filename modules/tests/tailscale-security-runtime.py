import ipaddress
import json
import shlex


# Only this disposable control plane issues credentials. No host auth-key
# aspect/autoconnect unit is imported, and no enrollment command runs after
# the initial two peers join. The key is revoked before any state transition.
TS = "timeout --kill-after=3s 10s tailscale --socket=/run/tailscale/tailscaled.sock"


def running(machine, package):
    machine.wait_for_unit("tailscaled.service", timeout=90)
    machine.wait_until_succeeds(
        f"{TS} status --json | jq -e '.BackendState == \"Running\"'",
        timeout=90,
    )
    pid = machine.succeed("systemctl show tailscaled.service --property=MainPID --value").strip()
    executable = machine.succeed(f"readlink -f /proc/{int(pid)}/exe").strip()
    assert executable.startswith(package + "/bin/"), executable
    assert machine.succeed("readlink -f /run/current-system/sw/bin/tailscale").strip().startswith(
        package + "/bin/"
    )


def identity(machine):
    status = json.loads(machine.succeed(f"{TS} status --json"))
    assert status["BackendState"] == "Running", status["BackendState"]
    addresses = sorted(status["Self"]["TailscaleIPs"])
    assert len(addresses) == 2, addresses
    assert sum(ipaddress.ip_address(ip) in ipaddress.ip_network("100.64.0.0/10")
               for ip in addresses if ":" not in ip) == 1, addresses
    assert sum(ipaddress.ip_address(ip) in ipaddress.ip_network("fd7a:115c:a1e0::/48")
               for ip in addresses if ":" in ip) == 1, addresses
    return {"id": status["Self"]["ID"], "addresses": addresses}


def preferences(machine):
    # Project inside the VM: do not copy private persisted keys into test logs.
    return json.loads(machine.succeed(
        f"{TS} debug prefs | jq '{{CorpDNS, RouteAll, ControlURL, WantRunning}}'"
    ))


def registrations():
    nodes = json.loads(headscale.succeed("timeout 10s headscale nodes list --output json"))
    assert len(nodes) == 2, nodes
    assert {node["given_name"] for node in nodes} == {"peer1", "peer2"}, nodes
    # Exclude online/last_seen and the preauthkey (a secret). These public
    # registration fields must remain exact, not just the number of nodes.
    return {
        node["given_name"]: {
            "id": node["id"],
            "machine_key": node["machine_key"],
            "addresses": sorted(node["ip_addresses"]),
            "created_at": node["created_at"],
            "user": node["user"]["id"],
        }
        for node in nodes
    }


def data_path():
    for source, target in [(peer1, peer2), (peer2, peer1)]:
        address = next(ip for ip in identities[target.name]["addresses"] if ":" not in ip)
        # Kernel ICMP and HTTP both traverse the real TUN interface. HTTP is
        # only allowed inbound on tailscale0, not the shared underlay VLAN.
        source.wait_until_succeeds(
            f"ping -I tailscale0 -c 1 -W 3 {address}", timeout=60
        )
        command = (
            "curl --fail --silent --show-error --noproxy '*' "
            f"--interface tailscale0 --connect-timeout 3 --max-time 5 http://{address}:8000/marker"
        )
        source.wait_until_succeeds(command, timeout=60)
        body = source.succeed(command)
        assert body == f"{target.name}-vpn-marker", (source.name, target.name, body)


def continuity(package):
    running(peer1, package)
    for machine in [peer1, peer2]:
        assert identity(machine) == identities[machine.name], machine.name
        assert preferences(machine) == expected_preferences, machine.name
    assert registrations() == original_registrations
    data_path()


def stop_cleanly():
    peer1.succeed("systemctl stop tailscaled.service")
    assert peer1.succeed("systemctl show tailscaled.service --property=Result --value").strip() == "success"
    assert peer1.succeed("systemctl show tailscaled.service --property=ActiveState --value").strip() == "inactive"
    assert peer1.succeed("systemctl show tailscaled.service --property=MainPID --value").strip() == "0"


start_all()
headscale.wait_for_unit("headscale.service", timeout=120)
headscale.wait_for_unit("nginx.service", timeout=90)
headscale.wait_for_open_port(443, timeout=90)
user = json.loads(headscale.succeed("timeout 10s headscale users create fixture --output json"))
key = json.loads(headscale.succeed(
    f"timeout 10s headscale preauthkeys create --user {int(user['id'])} "
    "--reusable --expiration 1h --output json"
))
expected_preferences = {
    "CorpDNS": False,
    "RouteAll": True,
    "ControlURL": "https://headscale",
    "WantRunning": True,
}
with subtest("old peers enroll once and exchange real VPN traffic"):
    assert old_version == "1.102.3"
    for machine in [peer1, peer2]:
        machine.wait_for_unit("tailscaled.service", timeout=90)
        machine.wait_for_unit("nginx.service", timeout=90)
        machine.succeed(
            "timeout --kill-after=3s 60s tailscale "
            "--socket=/run/tailscale/tailscaled.sock up --timeout=45s --login-server=https://headscale "
            f"--auth-key={shlex.quote(key['key'])} --hostname={machine.name} "
            "--accept-dns=false --accept-routes=true"
        )
        running(machine, old_package)
        assert json.loads(machine.succeed(f"{TS} status --json"))["Version"].split("-")[0] == old_version
        assert preferences(machine) == expected_preferences
    identities = {machine.name: identity(machine) for machine in [peer1, peer2]}
    assert identities["peer1"]["id"] != identities["peer2"]["id"]
    original_registrations = registrations()
    for name in ["peer1", "peer2"]:
        assert original_registrations[name]["addresses"] == identities[name]["addresses"]
    data_path()
    headscale.succeed(f"timeout 10s headscale preauthkeys expire --id {int(key['id'])}")
    del key

with subtest("clean old stop and cold state snapshot"):
    baseline_system = peer1.succeed("readlink -f /run/current-system").strip()
    stop_cleanly()
    peer1.succeed(
        "test -s /var/lib/tailscale/tailscaled.state",
        "cp -a /var/lib/tailscale /var/lib/tailscale-old-cold",
    )

with subtest("selected daemon and matching CLI reuse old identity without enrollment"):
    peer1.succeed(
        f"{baseline_system}/specialisation/security-update/bin/switch-to-configuration test",
        "systemctl start tailscaled.service",
    )
    continuity(selected_package)
    peer1.succeed("timeout --kill-after=3s 60s systemctl start tailscale-online.target")
    peer1.wait_for_unit("tailscale-wait-online.service", timeout=90)

with subtest("selected daemon restart retains identity preferences and VPN traffic"):
    peer1.succeed("systemctl restart tailscaled.service")
    continuity(selected_package)

with subtest("cold restore rollback to old daemon without reauthentication"):
    stop_cleanly()
    peer1.succeed(
        "rm -rf /var/lib/tailscale",
        "cp -a /var/lib/tailscale-old-cold /var/lib/tailscale",
        f"{baseline_system}/bin/switch-to-configuration test",
        "systemctl start tailscaled.service",
    )
    continuity(old_package)

# Coverage: isolated cold-state recovery only, not old-read-new-state,
# interruption-free upgrades, production backup proof, or restart approval.
# Native NixOS package/unit activation and selected online readiness are exercised;
# production auth secrets, physical boot and impermanence are not.
