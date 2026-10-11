# Runtime test for hvn-hyp1's host telemetry.
#
# The VM runs the socket, services, timers and firewall rule that hvn-hyp1
# deploys, unchanged, with a real ZFS pool on a file vdev. Network
# namespaces stand in for the compute guest, another source on the same
# bridge, and a LAN client. The test shows that:
# - activation succeeds while the Incus bridge does not exist yet, and the
#   exporter answers once the bridge appears;
# - only the guest address on the bridge can connect;
# - with the zpool-status timer stopped, zpool.prom keeps its modification
#   time while node_exporter keeps answering.
{
  lib,
  self,
  ...
}:
let
  hvnConfig = self.nixosConfigurations.hvn-hyp1.config;
  monitoring = hvnConfig.homelab.monitoring;
  units = [
    "host-telemetry-node-exporter"
    "host-telemetry-zpool-status"
    "host-telemetry-smart-status"
  ];
  copyService = name: {
    inherit (hvnConfig.systemd.services.${name})
      description
      wantedBy
      requires
      after
      serviceConfig
      ;
  };
  copyTimer = name: { inherit (hvnConfig.systemd.timers.${name}) wantedBy timerConfig; };
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      address = "${monitoring.listenAddress}:9100";
      test = pkgs.testers.runNixOSTest {
        name = "host-telemetry-runtime";
        requiredFeatures.kvm = true;
        nodes.machine =
          { pkgs, ... }:
          {
            system.stateVersion = "26.05";
            virtualisation.memorySize = 1536;
            # The test runs switch-to-configuration as activation does.
            system.switch.enable = true;
            boot.kernelPackages = hvnConfig.boot.kernelPackages;
            boot.supportedFilesystems = [ "zfs" ];
            boot.zfs.package = hvnConfig.boot.zfs.package;
            boot.zfs.forceImportRoot = false;
            networking.hostId = "8425e349";
            networking.nftables.enable = true;
            networking.firewall.enable = true;
            networking.firewall.extraInputRules = hvnConfig.networking.firewall.extraInputRules;
            environment.systemPackages = [
              pkgs.curl
              pkgs.iproute2
            ];
            systemd.tmpfiles.rules = lib.filter (lib.hasInfix "/run/host-telemetry") hvnConfig.systemd.tmpfiles.rules;
            systemd.sockets.host-telemetry-node-exporter = {
              inherit (hvnConfig.systemd.sockets.host-telemetry-node-exporter)
                description
                wantedBy
                socketConfig
                ;
            };
            systemd.services = lib.genAttrs units copyService;
            systemd.timers = lib.genAttrs [
              "host-telemetry-zpool-status"
              "host-telemetry-smart-status"
            ] copyTimer;
          };
        testScript = ''
          import re
          import time

          address = "${address}"
          guest = "${monitoring.guestAddress}"
          bridge = "${monitoring.interface}"

          def metric(text, name, **labels):
              for line in text.splitlines():
                  match = re.fullmatch(r'([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})? (\S+)', line)
                  if not match or match.group(1) != name:
                      continue
                  found = dict(re.findall(r'([a-zA-Z_]+)="([^"]*)"', match.group(2) or ""))
                  if all(found.get(key) == value or found.get(key, "").endswith("/" + value) for key, value in labels.items()):
                      return float(match.group(3))
              raise AssertionError(f"{name} {labels} missing")

          def scrape():
              return machine.succeed(f"ip netns exec guest curl -sf --max-time 10 http://{address}/metrics")

          start_all()
          machine.wait_for_unit("multi-user.target")

          with subtest("activation succeeds before the bridge exists"):
              machine.fail(f"ip link show {bridge}")
              machine.succeed("systemctl is-active host-telemetry-node-exporter.socket")
              machine.succeed("/run/current-system/bin/switch-to-configuration test >&2")
              failed = machine.succeed("systemctl list-units --state=failed --no-legend --plain").strip()
              assert failed == "", failed
              for unit in ("host-telemetry-node-exporter.service", "host-telemetry-zpool-status.service", "host-telemetry-smart-status.service"):
                  wanted = machine.succeed(f"systemctl show -p WantedBy --value {unit}").strip()
                  assert wanted == "", f"{unit} is wanted by {wanted}"
              print("EVIDENCE activation exit 0 with no bridge; socket active; no failed units")

          with subtest("a ZFS pool for the status timer"):
              machine.succeed("truncate -s 128M /var/tmp/vdev && zpool create -f rpool /var/tmp/vdev")

          with subtest("the exporter answers the guest once the bridge exists"):
              machine.succeed(
                  f"ip link add {bridge} type bridge && ip addr add {address.split(':')[0]}/24 dev {bridge} && ip link set {bridge} up",
                  "ip link add veth-guest type veth peer name veth-guest-br",
                  f"ip link set veth-guest-br master {bridge} up",
                  "ip netns add guest && ip link set veth-guest netns guest",
                  f"ip -n guest addr add {guest}/24 dev veth-guest && ip -n guest link set veth-guest up && ip -n guest link set lo up",
              )
              machine.wait_until_succeeds(f"ip netns exec guest curl -sf --max-time 5 http://{address}/metrics >/dev/null", timeout=60)
              print("EVIDENCE guest scrape ok after bridge creation")

          with subtest("only the guest address on the bridge can connect"):
              machine.succeed(
                  "ip link add veth-rogue type veth peer name veth-rogue-br",
                  f"ip link set veth-rogue-br master {bridge} up",
                  "ip netns add rogue && ip link set veth-rogue netns rogue",
                  "ip -n rogue addr add 10.210.0.20/24 dev veth-rogue && ip -n rogue link set veth-rogue up",
                  "ip link add veth-lan type veth peer name lan0",
                  "ip addr add 172.27.99.1/24 dev lan0 && ip link set lan0 up",
                  "ip netns add lan && ip link set veth-lan netns lan",
                  "ip -n lan addr add 172.27.99.2/24 dev veth-lan && ip -n lan link set veth-lan up",
                  "ip -n lan route add 10.210.0.0/24 via 172.27.99.1",
              )
              machine.fail(f"ip netns exec rogue curl -sf --max-time 5 http://{address}/metrics")
              machine.fail(f"ip netns exec lan curl -sf --max-time 5 http://{address}/metrics")
              machine.fail("ip netns exec lan curl -sf --max-time 5 http://172.27.99.1:9100/metrics")
              scrape()
              print("EVIDENCE other source on bridge refused; LAN interface refused; guest allowed")

          with subtest("the status services write their files under their sandboxes"):
              machine.succeed("systemctl start host-telemetry-zpool-status.service host-telemetry-smart-status.service")
              text = scrape()
              assert metric(text, "homelab_zpool_present", pool="rpool") == 1
              assert metric(text, "homelab_zpool_healthy", pool="rpool") == 1
              # The declared disks do not exist in the VM: each reports "not read".
              for disk in ${builtins.toJSON (builtins.attrNames monitoring.disks)}:
                  assert metric(text, "homelab_smart_device_up", disk=disk) == 0, disk
              assert metric(text, "node_textfile_scrape_error") == 0
              # Names the rules and the Watchdog read, from the pinned exporter.
              metric(text, "node_time_seconds")
              metric(text, "node_systemd_unit_state", state="failed")
              metric(text, "node_filesystem_size_bytes", mountpoint="/")
              metric(text, "node_filesystem_avail_bytes", mountpoint="/")
              print("EVIDENCE zpool.prom has rpool; smart.prom lists every declared disk")

          with subtest("a stopped timer leaves zpool.prom stale while the exporter answers"):
              first = metric(scrape(), "node_textfile_mtime_seconds", file="zpool.prom")
              time.sleep(2)
              machine.succeed("systemctl start host-telemetry-zpool-status.service")
              second = metric(scrape(), "node_textfile_mtime_seconds", file="zpool.prom")
              assert second > first, (first, second)
              machine.succeed("systemctl stop host-telemetry-zpool-status.timer")
              time.sleep(150)
              text = scrape()
              third = metric(text, "node_textfile_mtime_seconds", file="zpool.prom")
              assert third == second, (second, third)
              assert metric(text, "homelab_zpool_present", pool="rpool") == 1
              print(f"EVIDENCE mtime advanced {first}->{second}, then held at {third} for 150 s with the timer stopped")
        '';
      };
    in
    {
      checks =
        lib.optionalAttrs (lib.hasSuffix "-linux" system) {
          host-telemetry-converters =
            (pkgs.callPackage (self + "/pkgs/by-name/host-telemetry/package.nix") { }).passthru.tests;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
        host-telemetry-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-host-telemetry-runtime";
          };
        };
      };
    };
}
