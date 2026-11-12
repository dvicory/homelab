# Native unprivileged Incus/TUN proof plus complementary hostile bridge probes.
{
  config,
  den,
  inputs,
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        cluster = config.den.clusters.prod-home;
        inherit
          (import ./_compute-configurations.nix {
            inherit self lib system;
            hostName = cluster.hostName;
          })
          hostConfig
          ;
        public = {
          nodePort = 30444;
          originAddress = "100.64.0.1";
          peerAddress = "100.64.0.2";
          peerIPv6Address = "fd7a:115c:a1e0::2";
        };
        fixtureConfig = config // {
          den = config.den // {
            clusters = config.den.clusters // {
              prod-home = cluster // {
                ingress = cluster.ingress // {
                  inherit public;
                };
              };
            };
          };
        };
        hostEntity = config.den.hosts.${cluster.hostSystem}.${cluster.hostName};
        declaredDevices =
          (import ../den/hosts/hvn-hyp1/default.nix {
            config = fixtureConfig;
            inherit den inputs lib;
          }).den.hosts.x86_64-linux.hvn-hyp1.settings.virtualization.compute.devices;
        fixtureHost = hostEntity // {
          settings = hostEntity.settings // {
            virtualization = hostEntity.settings.virtualization // {
              compute = hostEntity.settings.virtualization.compute // {
                devices = declaredDevices;
              };
            };
          };
        };
        evaluatedCompute =
          (import ../den/aspects/virtualization/compute.nix {
            inherit den lib inputs;
            config = fixtureConfig;
          }).den.aspects.virtualization.compute.nixos
            {
              host = fixtureHost;
              config = hostConfig;
              inherit lib pkgs;
            };
        transport =
          (import ../den/aspects/services/public-edge.nix {
            config = fixtureConfig;
            inherit lib inputs;
          }).den.aspects.services;
        role =
          name:
          { config, ... }:
          transport."public-${name}".nixos {
            inherit config pkgs;
            host = {
              name = "fixture-${name}";
              settings.services."public-${name}" = {
                enable = true;
                authKeyFile = "/srv/secrets/tailscale-auth-key";
              };
            };
          };
        tailnet = import ./_public-entry-runtime/tailnet.nix { inherit pkgs lib; };
        descriptor = builtins.fromJSON evaluatedCompute.environment.etc."homelab/compute.json".text;
        tables = evaluatedCompute.networking.nftables.tables;
        bridge = descriptor.network;
        veth = descriptor.devices.eth0.host_name;
        bridgeAddress = lib.head (lib.splitString "/" descriptor.networkConfig."ipv4.address");
        guestAddress = descriptor.address;
        nodePort = cluster.ingress.nodePort;
        guestPorts = lib.unique [
          nodePort
          public.nodePort
          8443
          6443
          22
          8444
        ];
        stateDevice = descriptor.devices.tailscale-state;
        secretsDevice = descriptor.devices.secrets;
        guest = inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.pkgs = pkgs; }
            (inputs.nixpkgs + "/nixos/modules/virtualisation/lxc-container.nix")
            (tailnet.client "192.168.55.13")
            (role "origin")
            ({ ... }: {
              system.stateVersion = "26.05";
              networking.hostName = "fixture-origin";
              networking.useDHCP = true;
              networking.useNetworkd = true;
              networking.useHostResolvConf = false;
              networking.firewall.allowedTCPPorts = guestPorts;
              networking.nftables.enable = true;
              networking.nftables.flushRuleset = false;
              networking.nftables.tables.fixture-extra = {
                family = "inet";
                content = ''include "/run/fixture-nft-extra.nft"'';
              };
              networking.nftables.checkRuleset = false;
              systemd.services.nftables.preStart = "touch /run/fixture-nft-extra.nft";
              # Production early containment must beat these intentionally
              # reachable ordinary/private and IPv6 listeners.
              networking.nftables.tables.fixture-nodeport = {
                family = "inet";
                content = ''
                  chain prerouting {
                    type nat hook prerouting priority dstnat; policy accept;
                    ip daddr ${public.originAddress} tcp dport ${toString public.nodePort} dnat ip to 10.42.0.10:${toString public.nodePort}
                  }
                  chain source-proof {
                    type filter hook forward priority -90; policy accept;
                    iifname "tailscale0" ip saddr ${public.peerAddress} ip daddr 10.42.0.10 ct original ip daddr ${public.originAddress} ct original proto-dst ${toString public.nodePort} counter
                  }
                '';
              };
              boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
              environment.systemPackages = [
                pkgs.iproute2
                pkgs.nftables
                pkgs.socat
                pkgs.netcat-openbsd
                pkgs.jq
                pkgs.curl
                pkgs.bind
              ];
              systemd.services.fixture-listeners = {
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];
                path = [
                  pkgs.iproute2
                  pkgs.socat
                  pkgs.nftables
                ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  set -eu
                  ip netns add backend
                  ip link add backend-host type veth peer name eth0 netns backend
                  ip addr add 10.42.0.1/24 dev backend-host
                  ip link set backend-host up
                  ip -n backend link set lo up
                  ip -n backend addr add 10.42.0.10/24 dev eth0
                  ip -n backend link set eth0 up
                  ip -n backend route add default via 10.42.0.1
                  ${lib.concatMapStringsSep "\n" (port: ''
                    socat TCP4-LISTEN:${toString port},reuseaddr,fork 'SYSTEM:echo $SOCAT_PEERADDR; cat' &
                    socat TCP6-LISTEN:${toString port},ipv6only=1,reuseaddr,fork 'SYSTEM:echo $SOCAT_PEERADDR; cat' &
                    ip netns exec backend socat TCP4-LISTEN:${toString port},reuseaddr,fork 'SYSTEM:echo $SOCAT_PEERADDR; cat' &
                  '') guestPorts}
                '';
              };
            })
          ];
        };
        # Same immutable closure/unified metadata-rootfs shape as the existing
        # Incus mount fixture, but with the actual native NixOS daemon units.
        closure = pkgs.closureInfo { rootPaths = [ guest.config.system.build.toplevel ]; };
        image = pkgs.runCommand "incus-tailnet-guest.tar.gz" { } ''
          mkdir -p image/rootfs/{dev,proc,sys,tmp,etc,nix/store,sbin}
          cp -a $(cat ${closure}/store-paths) image/rootfs/nix/store/
          ln -s ${guest.config.system.build.toplevel}/init image/rootfs/sbin/init
          ln -s ${guest.config.system.build.toplevel}/etc/os-release image/rootfs/etc/os-release
          cp ${closure}/registration image/rootfs/nix-path-registration
          printf 'architecture: x86_64\ncreation_date: 1\nproperties:\n  description: native-tailnet-guest\n' > image/metadata.yaml
          tar -C image --owner=0 --group=0 --numeric-owner -czf $out metadata.yaml rootfs
        '';
        network = address: {
          system.stateVersion = "26.05";
          virtualisation.vlans = [ 1 ];
          networking.useDHCP = false;
          networking.interfaces.eth1.ipv4.addresses = [
            {
              inherit address;
              prefixLength = 24;
            }
          ];
          environment.systemPackages = [
            pkgs.netcat-openbsd
            pkgs.socat
            pkgs.jq
            pkgs.python3
            pkgs.curl
          ];
        };
      in
      {
        checks.compute-ingress-runtime = pkgs.testers.runNixOSTest {
          name = "compute-ingress-runtime";
          requiredFeatures.kvm = true;
          nodes = {
            control = tailnet.control "192.168.55.13";
            client = {
              imports = [
                (network "192.168.55.10")
                (tailnet.client "192.168.55.13")
              ];
              services.tailscale.authKeyFile = "/srv/secrets/tailscale-auth-key";
              services.tailscale.extraUpFlags = [
                "--accept-dns=false"
                "--accept-routes=false"
              ];
              networking.firewall.allowedTCPPorts = [ 18080 ];
            };
            relay = {
              imports = [
                (network "192.168.55.2")
                (tailnet.client "192.168.55.13")
                (role "relay")
              ];
              systemd.services.haproxy.wantedBy = lib.mkForce [ ];
              networking.firewall.allowedTCPPorts = [ 18080 ];
            };
            host = { config, ... }: {
              imports = [
                (tailnet.client "192.168.55.13")
                ../den/aspects/core/network/_firewall-lifetime.nix
              ];
              system.stateVersion = "26.05";
              virtualisation = {
                vlans = [ 1 ];
                cores = 2;
                memorySize = 3072;
                diskSize = 6144;
              };
              networking.useDHCP = false;
              networking.firewall.allowedTCPPorts = [
                22
                6443
                8443
                18080
              ];
              networking.firewall.trustedInterfaces = [
                bridge
                "tailscale0"
              ];
              services.tailscale.authKeyFile = "/srv/secrets/tailscale-auth-key";
              networking.firewall.checkReversePath = "loose";
              services.tailscale.openFirewall = true;
              systemd.services.tailscaled.serviceConfig.Environment = [ "TS_DEBUG_FIREWALL_MODE=nftables" ];
              services.tailscale.extraUpFlags = [
                "--accept-dns=false"
                "--accept-routes=false"
              ];
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
              boot.kernelModules = [
                "nft_meta_bridge"
                "tun"
              ];
              boot.kernel.sysctl = {
                "net.ipv4.ip_forward" = 1;
                "net.bridge.bridge-nf-call-iptables" = 0;
                "net.bridge.bridge-nf-call-ip6tables" = 0;
                "net.bridge.bridge-nf-call-arptables" = 0;
              };
              environment.systemPackages = [
                pkgs.iproute2
                pkgs.netcat-openbsd
                pkgs.nftables
                pkgs.socat
                pkgs.jq
                pkgs.python3
                pkgs.curl
              ];
              users.users.root = {
                subUidRanges = [
                  {
                    startUid = descriptor.idmapBase;
                    count = descriptor.idmapSize;
                  }
                ];
                subGidRanges = [
                  {
                    startGid = descriptor.idmapBase;
                    count = descriptor.idmapSize;
                  }
                ];
              };
              virtualisation.incus = {
                enable = true;
                preseed = {
                  storage_pools = [
                    {
                      name = "default";
                      driver = "dir";
                    }
                  ];
                  networks = [
                    {
                      name = bridge;
                      type = "bridge";
                      config = descriptor.networkConfig;
                    }
                  ];
                  profiles = [
                    {
                      name = "default";
                      config = {
                        "security.privileged" = "false";
                        "security.nesting" = "true";
                        "security.idmap.isolated" = "true";
                        "security.idmap.base" = toString descriptor.idmapBase;
                        "security.idmap.size" = toString descriptor.idmapSize;
                        "limits.memory" = "768MiB";
                        "limits.cpu" = "1";
                      };
                      devices = {
                        root = {
                          type = "disk";
                          pool = "default";
                          path = "/";
                        };
                        eth0 = descriptor.devices.eth0 // {
                          hwaddr = "02:00:00:21:00:10";
                        };
                        tailscale-state = removeAttrs stateDevice [ "requiredPath" ];
                        secrets = secretsDevice;
                      };
                    }
                  ];
                };
              };
              networking.nftables = {
                enable = true;
                flushRuleset = false;
                checkRuleset = false;
                tables = {
                  inherit (tables)
                    "homelab-compute-ingress"
                    "homelab-compute-boundary"
                    "homelab-compute-bridge-boundary"
                    ;
                  fixture-extra = {
                    family = "inet";
                    content = ''include "/run/fixture-nft-extra.nft"'';
                  };
                };
              };
              systemd.services.nftables.preStart = "touch /run/fixture-nft-extra.nft";
              systemd.services.fixture-listeners = {
                wantedBy = [ "multi-user.target" ];
                path = [ pkgs.socat ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  for port in 22 6443 8443 18080; do
                    socat TCP4-LISTEN:$port,reuseaddr,fork 'SYSTEM:echo $SOCAT_PEERADDR; cat' &
                    socat TCP6-LISTEN:$port,ipv6only=1,reuseaddr,fork 'SYSTEM:echo $SOCAT_PEERADDR; cat' &
                  done
                '';
              };
            };
          };
          testScript = ''
            import json
            import shlex
            q = shlex.quote
            start_all()
            control.wait_for_unit("headscale.service")
            control.wait_for_open_port(443)
            host.wait_for_unit("incus.service")
            # Required retained state is a real writable host mount, not a
            # directory accidentally surviving only inside the old rootfs.
            host.succeed("install -d -m 0700 ${stateDevice.source} ${secretsDevice.source}; "
                "mount --bind ${stateDevice.source} ${stateDevice.source}; "
                "chown ${toString descriptor.idmapBase}:${toString descriptor.idmapBase} ${stateDevice.source} ${secretsDevice.source}")
            host.succeed("systemctl start incus-preseed.service")
            host.wait_for_unit("incus-preseed.service")
            host.succeed("incus image import ${image} --alias native-tailnet; incus init native-tailnet origin; incus start origin")

            def guest(command):
                return host.succeed("incus exec --disable-stdin origin -- sh -c " + q(command)).strip()

            def guest_wait(command):
                host.wait_until_succeeds("incus exec --disable-stdin origin -- sh -c " + q(command), timeout=120)

            def enroll(machine, role, expected, container=False):
                control.succeed("fixture-enrollment " + role)
                exchange = "/tmp/shared/enrollment-" + role
                control.succeed(f"install -d -m 0700 {exchange}; cp /run/fixture-tailnet/{role}.key {exchange}/key")
                try:
                    if container:
                        host.succeed(f"install -m 0400 -o ${toString descriptor.idmapBase} -g ${toString descriptor.idmapBase} {exchange}/key ${secretsDevice.source}/tailscale-auth-key")
                        guest_wait("systemctl is-active multi-user.target tailscaled.service")
                        guest("systemctl start tailscaled-autoconnect.service")
                        guest_wait(f'test "$(tailscale ip -4)" = {expected}')
                        guest("systemctl start tailscaled-set.service")
                    else:
                        machine.succeed(f"install -d -m 0700 /srv/secrets; install -m 0400 {exchange}/key /srv/secrets/tailscale-auth-key; systemctl start tailscaled-autoconnect.service")
                        machine.wait_until_succeeds(f'test "$(tailscale ip -4)" = {expected}', timeout=90)
                        if role == "relay":
                            machine.succeed("systemctl start tailscaled-set.service")
                    state = json.loads(guest("tailscale status --json") if container else machine.succeed("tailscale status --json"))
                    expected_tag = "tag:" + ("public-" + role if role in ("origin", "relay") else role)
                    assert state["Self"]["Tags"] == [expected_tag]
                except Exception:
                    journal = "journalctl -b --no-pager -u tailscaled.service -u tailscaled-autoconnect.service"
                    if container:
                        print(host.execute("incus exec --disable-stdin origin -- " + journal)[1])
                    else:
                        print(machine.execute(journal)[1])
                    print(control.execute("journalctl -b --no-pager -u headscale.service")[1])
                    raise
                finally:
                    control.succeed(f"rm -rf {exchange}")

            # A fresh disposable DB allocates serially. Never derive the policy
            # from whichever random address an asynchronously started node got.
            enroll(host, "origin", "${public.originAddress}", container=True)
            enroll(relay, "relay", "${public.peerAddress}")
            enroll(host, "host", "100.64.0.3")
            enroll(client, "private", "100.64.0.4")
            guest_wait("systemctl is-active fixture-listeners.service")
            guest("test -c /dev/net/tun; ip -d link show tailscale0 | grep -q tun; test -w /var/lib/tailscale; test -r /srv/secrets/tailscale-auth-key")
            guest("test $(stat -c %a /var/lib/tailscale) = 700; test $(stat -c %a /srv/secrets/tailscale-auth-key) = 400")
            host.fail("incus exec --disable-stdin origin -- touch /srv/secrets/must-be-read-only")
            guest("touch /var/lib/tailscale/retention-proof")
            assert guest("cat /proc/self/uid_map").split() == ["0", "${toString descriptor.idmapBase}", "${toString descriptor.idmapSize}"]
            guest("ip -4 -o addr show eth0 | grep -q 'inet ${guestAddress}/24'")
            guest("ip route show default | grep -q '${bridgeAddress}'; dig +short @${bridgeAddress} -x ${guestAddress} | grep -q '^origin[.]'")
            # Native DHCP/DNS and Incus NAT: the external listener sees the host,
            # while LAN DNAT preserves its client. Native host Tailscale keeps
            # its existing subnet SNAT on; only the guest origin disables it.
            assert guest("nc -w2 192.168.55.1 18080").splitlines()[0] == "${guestAddress}"
            client.succeed("systemd-run --unit=nat-listener socat TCP4-LISTEN:18080,reuseaddr,fork 'SYSTEM:echo $SOCAT_PEERADDR'")
            client.wait_for_open_port(18080)
            assert guest("nc -w2 192.168.55.10 18080") == "192.168.55.1"
            for port in ${builtins.toJSON guestPorts}:
                guest(f"nc -z -w2 127.0.0.1 {port}; nc -6 -z -w2 ::1 {port}; ip netns exec backend nc -z -w2 10.42.0.10 {port}")
            for port in (22, 6443, 8443):
                host.succeed(f"nc -z -w2 127.0.0.1 {port}")
            assert client.wait_until_succeeds("nc -w2 192.168.55.1 443").strip() == "192.168.55.10"
            assert client.wait_until_succeeds("nc -w2 100.64.0.3 443").strip() == "${bridgeAddress}"
            assert relay.wait_until_succeeds("nc -w2 ${public.originAddress} ${toString public.nodePort}").strip() == "${public.peerAddress}"
            rules = json.loads(guest("nft -j list chain inet fixture-nodeport source-proof"))
            assert any(expr.get("counter", {}).get("packets", 0) > 0 for item in rules["nftables"] if "rule" in item for expr in item["rule"]["expr"]), "NodePort forwarding lost the relay source"

            def denied():
                for port in (${toString nodePort}, 443, 22, 6443, 8443, 8444):
                    relay.fail(f"nc -z -w1 ${public.originAddress} {port}")
                for destination in ("192.168.55.1", "${bridgeAddress}", "100.64.0.3"):
                    for port in (22, 6443, 8443):
                        relay.fail(f"nc -z -w1 {destination} {port}")
                        relay.fail(f"nc -6 -z -w1 fd7a:115c:a1e0::3 {port}")
                for destination in ("${guestAddress}", "10.42.0.10"):
                    for port in ${builtins.toJSON guestPorts}:
                        relay.fail(f"nc -z -w1 {destination} {port}")
                relay.fail(f"nc -6 -z -w1 {origin_v6} ${toString public.nodePort}")
                # Guest-created new Tailnet traffic cannot borrow host trust.
                for target in ("100.64.0.3", "100.64.0.4", "${public.peerAddress}"):
                    host.fail("incus exec --disable-stdin origin -- nc -z -w1 " + target + " 18080")

            # Hostile real routed alternative to a peer's narrow route map.
            # Remove the compromised relay's local restrictions, not the origin
            # production policy. Qualify destinations locally before negatives.
            relay.succeed("nft delete table inet public-transport; tailscale set --accept-routes=true")
            relay.succeed("systemd-run --unit=egress-target socat TCP4-LISTEN:18080,reuseaddr,fork 'SYSTEM:echo $SOCAT_PEERADDR'")
            relay.wait_for_open_port(18080)
            client.succeed("nc -z -w2 192.168.55.2 18080")
            guest("tailscale set --advertise-routes=10.42.0.0/24,${guestAddress}/32,${bridgeAddress}/32,192.168.55.1/32")
            control.succeed("headscale nodes approve-routes --identifier 1 --routes 10.42.0.0/24,${guestAddress}/32,${bridgeAddress}/32,192.168.55.1/32 > /run/fixture-route-approval")
            relay.wait_until_succeeds("ip route show table 52 | grep -q '10.42.0.0/24.*tailscale0'", timeout=90)
            origin_v6 = "fd7a:115c:a1e0::1"
            assert guest("tailscale ip -6") == origin_v6
            assert relay.succeed("tailscale ip -6").strip() == "${public.peerIPv6Address}"
            assert host.succeed("tailscale ip -6").strip() == "fd7a:115c:a1e0::3"
            assert client.succeed("tailscale ip -6").strip() == "fd7a:115c:a1e0::4"
            host.succeed("nc -6 -z -w2 fd7a:115c:a1e0::3 22")
            relay.succeed("ip -6 route get " + origin_v6 + " | grep -q tailscale0")
            denied()
            # Keep one already-established private Tailnet->host DNAT flow
            # alive while testing host/guest firewall lifecycle. A new egress
            # ban must not drop the guest's legitimate replies.
            stream = (
                "import socket,time,pathlib; "
                "s=socket.create_connection(('100.64.0.3',443),5); s.settimeout(5); "
                "f=s.makefile('rb'); assert f.readline().strip()==b'${bridgeAddress}'; "
                "p=pathlib.Path('/run/private-replies'); n=0\n"
                "while not pathlib.Path('/run/stop-private-replies').exists():\n"
                " s.sendall(b'private-live\\n'); assert f.readline()==b'private-live\\n'; "
                "n+=1; p.write_text(str(n)); time.sleep(.1)\n"
            )
            client.succeed("systemd-run --unit=private-replies python3 -c " + q(stream))
            client.wait_until_succeeds("test -s /run/private-replies")

            def private_survives():
                before = int(client.succeed("cat /run/private-replies"))
                client.wait_until_succeeds(f"test $(cat /run/private-replies) -gt {before}", timeout=15)
                client.succeed("systemctl is-active private-replies.service")

            def public_works():
                assert relay.succeed("nc -w2 ${public.originAddress} ${toString public.nodePort}").strip() == "${public.peerAddress}"

            def host_egress_blocked():
                # Exercise natural fallback with the guest daemon down. Its
                # own routing and anti-spoof rules must not mask the host guard.
                client.succeed("nc -z -w2 100.64.0.4 18080")
                guest("systemctl stop tailscaled.service")
                try:
                    host.fail("incus exec --disable-stdin origin -- nc -z -w2 100.64.0.4 18080")
                    private_survives()
                finally:
                    guest("systemctl start tailscaled.service")
                assert relay.wait_until_succeeds("nc -w2 ${public.originAddress} ${toString public.nodePort}", timeout=90).strip() == "${public.peerAddress}"

            for container in (False, True):
                run = guest if container else lambda cmd: host.succeed(cmd).strip()
                fail = (lambda cmd: host.fail("incus exec --disable-stdin origin -- sh -c " + q(cmd))) if container else host.fail
                table = "public-transport" if container else "homelab-compute-boundary"
                ownership = run("cat /var/lib/nftables/deletions.nft")
                run("systemctl stop nftables.service")
                run("nft list table inet " + table)
                assert run("cat /var/lib/nftables/deletions.nft") == ownership
                # These remain native enrolled TUN endpoints while the unit is
                # stopped; a missing daemon must not explain negative probes.
                run("tailscale status --json | jq -e '.BackendState == \"Running\"' >/dev/null")
                denied()
                public_works()
                if not container:
                    host_egress_blocked()
                private_survives()
                run("systemctl start nftables.service; systemctl reload nftables.service")
                denied()
                public_works()
                if not container:
                    host_egress_blocked()
                private_survives()
                # Corrupt only the fixture include: exercise the real native
                # ExecReload transaction, including saved ownership semantics.
                run("printf 'this is not valid nft syntax\\n' > /run/fixture-nft-extra.nft")
                fail("systemctl reload nftables.service")
                run("nft list table inet " + table)
                assert run("cat /var/lib/nftables/deletions.nft") == ownership
                denied()
                public_works()
                if not container:
                    host_egress_blocked()
                private_survives()
                run(": > /run/fixture-nft-extra.nft; systemctl reload nftables.service")

            # Without the host barrier, fallback with the guest daemon down
            # would borrow the host's identity. Restore protection immediately.
            guest("systemctl stop tailscaled.service")
            try:
                host.fail("incus exec --disable-stdin origin -- nc -z -w2 100.64.0.4 18080")
                host.succeed("nft delete table inet homelab-compute-boundary")
                try:
                    assert guest("nc -w2 100.64.0.4 18080").splitlines()[0] == "100.64.0.3"
                finally:
                    host.succeed("systemctl reload nftables.service")
                host.fail("incus exec --disable-stdin origin -- nc -z -w2 100.64.0.4 18080")
                private_survives()
            finally:
                guest("systemctl start tailscaled.service")
            assert relay.wait_until_succeeds("nc -w2 ${public.originAddress} ${toString public.nodePort}", timeout=90).strip() == "${public.peerAddress}"
            client.succeed("touch /run/stop-private-replies")
            client.wait_until_succeeds("test $(systemctl show private-replies.service -p ActiveState --value) = inactive")

            # Bridge probes complement native daemon evidence; these namespaces
            # are deliberately not presented as tailscaled endpoints.
            host.succeed("ip netns add bridgepeer; ip link add bridgepeer-host type veth peer name eth0 netns bridgepeer; "
                "ip link set bridgepeer-host master ${bridge} up; ip -n bridgepeer link set lo up; "
                "ip -n bridgepeer link set eth0 address 02:00:00:21:00:fe; ip -n bridgepeer link set eth0 up; "
                "ip -n bridgepeer addr add 10.210.0.254/24 dev eth0; "
                "ip -n bridgepeer addr add ${public.peerAddress}/32 dev eth0; "
                "ip -n bridgepeer route add ${guestAddress}/32 dev eth0; "
                "ip -n bridgepeer route add default via ${bridgeAddress}; "
                "ip -n bridgepeer neigh replace ${guestAddress} lladdr 02:00:00:21:00:10 nud permanent dev eth0")
            guest("ip neigh replace 10.210.0.254 lladdr 02:00:00:21:00:fe nud permanent dev eth0")
            host.succeed("ip netns exec bridgepeer nc -s 10.210.0.254 -z -w2 ${guestAddress} ${toString nodePort}")
            # Qualify spoof replies through eth0, not the legitimate TUN route.
            guest("ip route add ${public.peerAddress}/32 dev eth0 table 100; ip rule add priority 50 to ${public.peerAddress}/32 lookup 100; "
                "ip neigh replace ${public.peerAddress} lladdr 02:00:00:21:00:fe nud permanent dev eth0")
            for port in ${builtins.toJSON guestPorts}:
                host.fail(f"ip netns exec bridgepeer nc -s ${public.peerAddress} -z -w1 ${guestAddress} {port}")
            for port in (22, 6443, 8443):
                host.fail(f"ip netns exec bridgepeer nc -s ${public.peerAddress} -z -w1 ${bridgeAddress} {port}")
            guest("ip rule del priority 50; ip route flush table 100")
            # Authenticated but wrong source: the ordinary Tailnet client is not
            # the declared relay, even though control ACL permits the traffic.
            client.fail("nc -z -w2 ${public.originAddress} ${toString public.nodePort}")

            identity = json.loads(guest("tailscale status --json"))["Self"]
            node_ids = json.loads(control.succeed("headscale nodes list --output json | jq '[.[] | {id, ip_addresses}]'"))
            host.succeed("rm ${secretsDevice.source}/tailscale-auth-key")
            guest("systemctl restart tailscaled.service; systemctl restart tailscaled-autoconnect.service")
            guest_wait('test "$(tailscale ip -4)" = ${public.originAddress}')
            assert json.loads(guest("tailscale status --json"))["Self"]["ID"] == identity["ID"]
            host.succeed("incus restart origin --force")
            guest_wait('test "$(tailscale ip -4)" = ${public.originAddress}')
            assert json.loads(guest("tailscale status --json"))["Self"]["ID"] == identity["ID"]
            guest_wait("systemctl is-active fixture-listeners.service")
            assert relay.wait_until_succeeds("nc -w2 ${public.originAddress} ${toString public.nodePort}").strip() == "${public.peerAddress}"
            # Replace the whole rootfs; only the declared retained attachment
            # carries native machine identity, with no enrollment input left.
            host.succeed("incus delete origin --force; incus init native-tailnet origin; incus start origin")
            guest_wait('test "$(tailscale ip -4)" = ${public.originAddress}')
            assert json.loads(guest("tailscale status --json"))["Self"]["ID"] == identity["ID"]
            guest("test -f /var/lib/tailscale/retention-proof")
            assert json.loads(control.succeed("headscale nodes list --output json | jq '[.[] | {id, ip_addresses}]'")) == node_ids
            guest_wait("systemctl is-active fixture-listeners.service")
            assert relay.wait_until_succeeds("nc -w2 ${public.originAddress} ${toString public.nodePort}").strip() == "${public.peerAddress}"
            denied()
            # No last-approved policy exists for this endpoint after explicit
            # removal. Its native startup prerequisite must keep it offline.
            guest("systemctl stop tailscaled.service; nft delete table inet public-transport")
            host.fail("incus exec --disable-stdin origin -- systemctl start tailscaled.service")
            host.fail("incus exec --disable-stdin origin -- ip link show tailscale0")
            guest("systemctl reload nftables.service; systemctl start tailscaled.service; systemctl start tailscaled-autoconnect.service; systemctl start tailscaled-set.service")
            assert relay.wait_until_succeeds("nc -w2 ${public.originAddress} ${toString public.nodePort}").strip() == "${public.peerAddress}"
            guest("systemctl stop tailscaled.service")
            assert client.succeed("nc -w2 192.168.55.1 443").strip() == "192.168.55.10"
            assert client.succeed("nc -w2 100.64.0.3 443").strip() == "${bridgeAddress}"
            client.succeed("nc -z -w2 192.168.55.1 22")
            print("EVIDENCE native-compute-tailnet: Incus-managed DHCP/DNS/NAT bridge, unprivileged native TUN, retained identity across daemon/container/rootfs replacement, original relay source and qualified IPv4/IPv6/bridge/routed isolation")
          '';
        };
      }
    );
}
