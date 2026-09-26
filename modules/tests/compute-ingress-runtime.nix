# Behavioural check of the direct household ingress: an external client's TCP
# 443 is DNAT'd to the compute guest's NodePort with the client source address
# preserved, while every other host port and every other guest port stays
# closed. The nftables tables under test are the evaluated production rules —
# this fixture only reproduces the interface and bridge names they reference.
{
  config,
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs
      (lib.elem system [
        "x86_64-linux"
        "aarch64-linux"
      ])
      (
        let
          inherit
            (import ./_compute-configurations.nix {
              inherit self lib system;
              hostName = config.den.clusters.prod-home.hostName;
            })
            hostConfig
            ;
          descriptor = builtins.fromJSON hostConfig.environment.etc."homelab/compute.json".text;
          tables = hostConfig.networking.nftables.tables;
          bridge = descriptor.network;
          veth = descriptor.devices.eth0.host_name;
          bridgeAddress = lib.head (lib.splitString "/" descriptor.networkConfig."ipv4.address");
          guestAddress = descriptor.address;
          nodePort = config.den.clusters.prod-home.ingress.nodePort;
          test = pkgs.testers.runNixOSTest {
            name = "compute-ingress-runtime";
            requiredFeatures.kvm = true;
            nodes = {
              client =
                { ... }:
                {
                  system.stateVersion = "26.05";
                  virtualisation.vlans = [ 1 ];
                  networking.useDHCP = false;
                  networking.interfaces.eth1.ipv4.addresses = [
                    {
                      address = "192.168.55.10";
                      prefixLength = 24;
                    }
                  ];
                  networking.firewall.enable = false;
                  environment.systemPackages = [ pkgs.netcat-openbsd ];
                };
              host =
                { lib, pkgs, ... }:
                {
                  system.stateVersion = "26.05";
                  virtualisation.vlans = [ 1 ];
                  networking.useDHCP = false;
                  networking.firewall.enable = true;

                  # The vlan NIC carries the production LAN name so the real
                  # iifname set matches it.
                  systemd.network.links."10-eno1" = {
                    matchConfig.OriginalName = "eth1";
                    linkConfig.Name = "eno1";
                  };
                  networking.interfaces.eno1.ipv4.addresses = [
                    {
                      address = "192.168.55.1";
                      prefixLength = 24;
                    }
                  ];
                  boot.kernelModules = [ "nft_meta_bridge" ];

                  # Incus bridge stand-in plus the veth the guest would hold;
                  # the guest itself is a network namespace with the declared
                  # guest address routed back through the bridge.
                  systemd.services.compute-bridge = {
                    description = "compute bridge and guest namespace fixture";
                    wantedBy = [ "multi-user.target" ];
                    before = [ "compute-guest-listeners.service" ];
                    after = [
                      "systemd-networkd.service"
                      "network-pre.target"
                    ];
                    path = [ pkgs.iproute2 ];
                    serviceConfig = {
                      Type = "oneshot";
                      RemainAfterExit = true;
                    };
                    script = ''
                      ip link add ${bridge} type bridge
                      ip link set ${bridge} up
                      ip addr add ${descriptor.networkConfig."ipv4.address"} dev ${bridge}
                      ip netns add guest
                      ip link add ${veth} type veth peer name veth0 netns guest
                      ip link set ${veth} master ${bridge} up
                      ip -n guest link set lo up
                      ip -n guest link set veth0 up
                      ip -n guest addr add ${guestAddress}/24 dev veth0
                      ip -n guest route add default via ${bridgeAddress}
                    '';
                  };

                  # socat echoes the peer's address: a reply proves reachability
                  # and identifies the source the guest would observe.
                  systemd.services.compute-guest-listeners = {
                    description = "guest listener stand-in on the declared guest address";
                    wantedBy = [ "multi-user.target" ];
                    after = [ "compute-bridge.service" ];
                    path = [
                      pkgs.iproute2
                      pkgs.socat
                    ];
                    serviceConfig = {
                      Type = "oneshot";
                      RemainAfterExit = true;
                      ExecStart = pkgs.writeShellScript "guest-listeners" ''
                        set -eu
                        ip netns exec guest socat TCP-LISTEN:${toString nodePort},reuseaddr,fork "SYSTEM:echo \$SOCAT_PEERADDR" &
                        ip netns exec guest socat TCP-LISTEN:8443,reuseaddr,fork "SYSTEM:echo \$SOCAT_PEERADDR" &
                      '';
                    };
                  };

                  # The real evaluated tables, not redeclared copies.
                  networking.nftables = {
                    enable = true;
                    tables = {
                      inherit (tables)
                        "homelab-compute-ingress"
                        "homelab-compute-boundary"
                        "homelab-compute-bridge-boundary"
                        ;
                    };
                  };

                  # Forwarding mirrors the aspect's own sysctl for direct
                  # ingress; bridge netfilter stays off as declared there.
                  boot.kernel.sysctl = {
                    "net.ipv4.ip_forward" = 1;
                    "net.bridge.bridge-nf-call-iptables" = 0;
                    "net.bridge.bridge-nf-call-ip6tables" = 0;
                    "net.bridge.bridge-nf-call-arptables" = 0;
                  };
                };
            };
            testScript = ''
              start_all()
              host.wait_for_unit("nftables.service")
              host.succeed("nft list chain inet homelab-compute-ingress ingress")
              host.wait_for_unit("compute-guest-listeners.service")
              host.wait_until_succeeds(
                  "ip netns exec guest ss -tln | grep -q ':${toString nodePort} '"
              )

              # (1)+(2): client -> host:443 reaches the guest NodePort and the
              # guest observes the client's own source address.
              observed = client.wait_until_succeeds(
                  "nc -w5 192.168.55.1 443"
              ).strip()
              assert observed == "192.168.55.10", f"guest saw {observed!r}, expected the client source address"

              # (3): host-side ports stay refused.
              for port in (${toString nodePort}, 6443, 80):
                  client.fail("nc -z -w2 192.168.55.1 %d" % port)

              # (4): nothing else on the guest is reachable through the host.
              client.fail("nc -z -w2 192.168.55.1 8443")
            '';
          };
        in
        {
          checks.compute-ingress-runtime = test;
        }
      );
}
