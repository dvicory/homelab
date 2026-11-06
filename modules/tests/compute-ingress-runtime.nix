# Exercise the evaluated host INPUT policy and Gateway FORWARD/DNAT path with
# real nftables. Namespaces stand in for decrypted Tailnet and compute traffic;
# they do not prove Tailscale authentication, discovery or ad hoc consumers.
{
  config,
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    # Hosted aarch64 runners have no KVM; x86_64 matches prod-home-replacement.
    lib.optionalAttrs (system == "x86_64-linux") (
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
        hostEntity = config.den.hosts.${system}.${config.den.clusters.prod-home.hostName};
        lanInterface = lib.head (
          lib.attrNames (
            lib.filterAttrs (_: iface: (iface.gateway or null) != null) hostEntity.networking.interfaces
          )
        );
        tailInterface = hostConfig.services.tailscale.interfaceName;
        transportPort = toString hostConfig.services.tailscale.port;
        metricPorts = lib.unique (
          map (
            target: lib.toInt (lib.last (lib.splitString ":" target.address))
          ) hostConfig.homelab.monitoring.scrapeTargets
        );
        nodePort = config.den.clusters.prod-home.ingress.nodePort;
        deniedHostPorts = [
          nodePort
          6443
          80
          18080
        ];
        hostListenerPorts = lib.unique (metricPorts ++ deniedHostPorts);
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
                networking.interfaces.eth1.ipv4.routes = [
                  {
                    address = bridgeAddress;
                    prefixLength = 32;
                    via = "192.168.55.1";
                  }
                  {
                    address = guestAddress;
                    prefixLength = 32;
                    via = "192.168.55.1";
                  }
                ];
                environment.systemPackages = [
                  pkgs.netcat-openbsd
                  pkgs.openssh
                  pkgs.bind
                ];
              };
            host =
              { lib, pkgs, ... }:
              {
                system.stateVersion = "26.05";
                virtualisation.vlans = [ 1 ];
                networking.useDHCP = false;
                # Copy the consumer-visible policy, not a hand-built allowlist.
                networking.firewall = {
                  inherit (hostConfig.networking.firewall)
                    enable
                    trustedInterfaces
                    checkReversePath
                    extraReversePathFilterRules
                    rejectPackets
                    allowPing
                    pingLimit
                    allowedTCPPorts
                    allowedTCPPortRanges
                    allowedUDPPorts
                    allowedUDPPortRanges
                    interfaces
                    extraInputRules
                    filterForward
                    extraForwardRules
                    ;
                };
                services.openssh = {
                  inherit (hostConfig.services.openssh) enable ports settings;
                };
                virtualisation.incus = {
                  inherit (hostConfig.virtualisation.incus) enable package ui;
                  preseed.config = hostConfig.virtualisation.incus.preseed.config;
                };
                virtualisation.memorySize = 2048;
                environment.systemPackages = [
                  pkgs.curl
                  pkgs.jq
                  pkgs.openssl
                  pkgs.openssh
                  pkgs.netcat-openbsd
                  pkgs.bind
                  pkgs.busybox
                  pkgs.socat
                ];

                # The vlan NIC carries the production LAN name so the real
                # iifname set matches it.
                systemd.network.links."10-management-lan" = {
                  matchConfig.OriginalName = "eth1";
                  linkConfig.Name = lanInterface;
                };
                networking.interfaces.${lanInterface}.ipv4.addresses = [
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
                    ip netns add tail
                    ip link add ${tailInterface} type veth peer name veth-tail netns tail
                    ip addr add 100.64.0.1/24 dev ${tailInterface}
                    ip link set ${tailInterface} up
                    ip -n tail link set lo up
                    ip -n tail link set veth-tail up
                    ip -n tail addr add 100.64.0.2/24 dev veth-tail
                    ip -n tail route add default via 100.64.0.1
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

                # Actual Incus daemon/UI, with disposable server and client
                # identities. Nothing here consumes production credentials.
                systemd.services.fixture-incus-tls = {
                  wantedBy = [ "multi-user.target" ];
                  before = [ "incus.service" ];
                  serviceConfig.Type = "oneshot";
                  script = ''
                    install -d -m 0700 /var/lib/incus
                    ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
                      -subj /CN=fixture-incus \
                      -addext 'subjectAltName=IP:100.64.0.1,IP:192.168.55.1,IP:${bridgeAddress}' \
                      -keyout /var/lib/incus/server.key -out /var/lib/incus/server.crt
                    chmod 0600 /var/lib/incus/server.key
                  '';
                };
                systemd.services.incus = {
                  requires = [ "fixture-incus-tls.service" ];
                  after = [ "fixture-incus-tls.service" ];
                };

                systemd.services.fixture-dns-dhcp = {
                  wantedBy = [ "multi-user.target" ];
                  after = [ "compute-bridge.service" ];
                  requires = [ "compute-bridge.service" ];
                  script = ''
                    exec ${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --bind-interfaces \
                      --interface=${bridge} --no-resolv --no-hosts --user=root \
                      --address=/fixture.test/192.0.2.1 --no-ping \
                      --dhcp-leasefile=/run/fixture-dnsmasq.leases \
                      --dhcp-range=${guestAddress},${guestAddress},255.255.255.0,1h
                  '';
                };

                # Listeners deliberately bind all addresses: a refused probe
                # must demonstrate firewall denial, not an absent socket.
                systemd.services.fixture-host-listeners = {
                  wantedBy = [ "multi-user.target" ];
                  path = [ pkgs.socat ];
                  serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    ExecStart = pkgs.writeShellScript "host-listeners" ''
                      set -eu
                      ${lib.concatMapStringsSep "\n" (
                        port: "socat TCP-LISTEN:${toString port},reuseaddr,fork EXEC:cat &"
                      ) hostListenerPorts}
                      socat UDP4-RECVFROM:${transportPort},reuseaddr,fork EXEC:cat &
                      socat UDP4-RECVFROM:18080,reuseaddr,fork EXEC:cat &
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
            import json
            import shlex
            from ipaddress import IPv4Address

            start_all()
            host.wait_for_unit("nftables.service")
            host.succeed("nft list chain inet homelab-compute-ingress ingress")
            for unit in ("compute-guest-listeners", "fixture-host-listeners", "fixture-dns-dhcp", "incus-preseed", "sshd"):
                host.wait_for_unit(unit + ".service", timeout=120)
            host.wait_until_succeeds(
                "ip netns exec guest ss -tln | grep -q ':${toString nodePort} '"
            )
            host.wait_until_succeeds("ip netns exec guest nc -z -w2 ${guestAddress} 8443")
            host.wait_for_open_port(8443)
            for port in ${builtins.toJSON hostListenerPorts}:
                host.wait_for_open_port(port)

            # Both production ingress interfaces retain DNAT and client source.
            for machine, prefix, address, source in (
                (client, "", "192.168.55.1", "192.168.55.10"),
                (host, "ip netns exec tail ", "100.64.0.1", "100.64.0.2"),
            ):
                observed = machine.wait_until_succeeds(prefix + f"nc -w3 {address} 443").strip()
                assert observed == source, f"guest saw {observed!r}, expected {source}"
                for port in ${builtins.toJSON deniedHostPorts}:
                    machine.fail(prefix + f"nc -z -w2 {address} {port}")
                # Direct guest access must fail in FORWARD, independently of
                # the host INPUT tests and the admitted Gateway DNAT path.
                machine.fail(prefix + "nc -z -w2 ${guestAddress} 8443")
                result = machine.succeed(prefix + f"sh -c 'printf transport | nc -u -w2 {address} ${transportPort}'")
                assert result == "transport", result
                _, result = machine.execute(prefix + f"sh -c 'printf denied | nc -u -w2 {address} 18080'")
                assert not result, result

            # The socket exists and works on Tailnet; LAN and compute may not
            # reach it, including the host's bridge address from the guest.
            host.succeed("ip netns exec tail nc -z -w2 100.64.0.1 8443")
            client.fail("nc -z -w2 192.168.55.1 8443")
            host.fail("ip netns exec guest nc -z -w2 ${bridgeAddress} 8443")
            host.fail("ip netns exec guest nc -z -w2 ${bridgeAddress} 18080")

            # Service-local bridge DNS (UDP and TCP), DHCP, and source-scoped
            # metrics remain admitted; Tailnet/LAN are not bridge consumers.
            for tcp in ("", "+tcp"):
                result = host.succeed(f"ip netns exec guest dig +short {tcp} @${bridgeAddress} fixture.test")
                assert result.strip() == "192.0.2.1", result
                for machine, prefix in ((client, ""), (host, "ip netns exec tail ")):
                    machine.fail(prefix + f"dig +time=1 +tries=1 {tcp} @${bridgeAddress} fixture.test")
            host.succeed("ip netns exec guest busybox udhcpc -i veth0 -n -q -t 3 -T 2 -s /bin/true")
            denied_source = str(IPv4Address("${guestAddress}") + 1)
            for port in ${builtins.toJSON metricPorts}:
                host.succeed(f"ip netns exec guest nc -z -w2 ${bridgeAddress} {port}")
                client.fail(f"nc -z -w2 ${bridgeAddress} {port}")
                host.fail(f"ip netns exec tail nc -z -w2 ${bridgeAddress} {port}")
                host.succeed(f"ip -n guest addr add {denied_source}/24 dev veth0")
                host.fail(f"ip netns exec guest nc -s {denied_source} -z -w2 ${bridgeAddress} {port}")
                host.succeed(f"ip -n guest addr del {denied_source}/24 dev veth0")

            # Normal trusted TLS UI/API smoke only. The test driver reads the
            # synthetic key locally; the request still crosses host INPUT.
            host.succeed("openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=fixture-client -keyout /run/client.key -out /run/client.crt")
            host.succeed("incus --force-local config trust add-certificate /run/client.crt --name fixture-client")
            curl = ("ip netns exec tail curl --fail --silent --show-error --connect-timeout 3 --max-time 10 "
                    "--cacert /var/lib/incus/server.crt --cert /run/client.crt --key /run/client.key ")
            api = json.loads(host.succeed(curl + "https://100.64.0.1:8443/1.0"))
            assert api["metadata"]["auth"] == "trusted", api
            host.succeed(curl + "https://100.64.0.1:8443/1.0/projects")
            host.succeed(curl + "--output /dev/null https://100.64.0.1:8443/ui/")
            host.succeed("ip link set ${tailInterface} down")

            # Real authenticated SSH on LAN, then local-socket Incus: recovery
            # does not traverse Tailnet, the UI, or an identity provider.
            client.succeed('ssh-keygen -q -t ed25519 -N "" -f /root/recovery')
            public_key = client.succeed("cat /root/recovery.pub").strip()
            host.succeed("install -d -m 0700 /root/.ssh; printf '%s\\n' " + shlex.quote(public_key) + " > /root/.ssh/authorized_keys")
            ssh = "ssh -i /root/recovery -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new -o BatchMode=yes root@192.168.55.1 "
            recovered = client.succeed(ssh + shlex.quote("incus --force-local query /1.0"))
            assert json.loads(recovered)["api_version"] == "1.0", recovered

          '';
        };
      in
      {
        checks.compute-ingress-runtime = test;
      }
    );
}
