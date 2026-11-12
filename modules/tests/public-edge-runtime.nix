{
  config,
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
        k3s = self.nixosConfigurations.compute-1.config.services.k3s.package;
        fixture = import ./_kubernetes-api/gateway/fixtures.nix {
          inherit
            config
            inputs
            lib
            pkgs
            self
            ;
          linuxPkgs = pkgs;
        };
        public = {
          originAddress = "100.64.0.1";
          peerAddress = "100.64.0.2";
          peerIPv6Address = "fd7a:115c:a1e0::2";
          nodePort = fixture.settings.publicNodePort;
        };
        transport =
          (import ../den/aspects/services/public-edge.nix {
            inherit inputs lib;
            config.den.clusters.prod-home.ingress = {
              nodePort = fixture.settings.nodePort;
              inherit public;
            };
          }).den.aspects.services;
        tailnet = import ./_public-entry-runtime/tailnet.nix { inherit pkgs lib; };
        role =
          name: settings:
          { config, pkgs, ... }:
          transport."public-${name}".nixos {
            inherit config pkgs;
            host = {
              name = "fixture-${name}";
              settings.services."public-${name}" = {
                enable = true;
                authKeyFile = "/srv/secrets/tailscale-auth-key";
              }
              // settings;
            };
          };
        network = address: {
          system.stateVersion = "26.05";
          networking.useDHCP = false;
          networking.interfaces.eth1.ipv4.addresses = [
            {
              inherit address;
              prefixLength = 24;
            }
          ];
          virtualisation.vlans = [ 1 ];
          environment.systemPackages = [
            pkgs.curl
            pkgs.jq
            pkgs.openssl
            pkgs.python3
            pkgs.tailscale
            pkgs.netcat-openbsd
          ];
        };
        settings = pkgs.writeText "public-entry-native-fixture.json" (
          builtins.toJSON (
            fixture.settings
            // {
              publicIngress = public;
              nodeAddress = "10.1.0.10";
              underlayAddress = "10.0.0.10";
              relayAddress = "10.0.0.11";
              clientAddress = "10.0.0.12";
              privateClientAddress = "10.1.0.12";
              kubectl = "${k3s}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml";
              transportProbe = "${./_public-entry-runtime/transport.py}";
              networkPolicy = "${../../generated/manifests/prod-home/network-policy}";
              python = "${pkgs.python3.withPackages (ps: [ ps.playwright ])}/bin/python3";
              chromium = "${pkgs.chromium}/bin/chromium";
            }
          )
        );
        test =
          (pkgs.testers.runNixOSTest {
            name = "public-edge-runtime";
            requiredFeatures.kvm = true;
            nodes = {
              origin = {
                imports = [
                  (network "10.0.0.10")
                  (tailnet.client "10.0.0.13")
                  (role "origin" { })
                ];
                networking.hostName = lib.mkForce "compute-1";
                networking.interfaces.eth0.useDHCP = true;
                networking.interfaces.eth2.ipv4.addresses = [
                  {
                    address = "10.1.0.10";
                    prefixLength = 24;
                  }
                ];
                networking.firewall.allowedTCPPorts = lib.mkForce [ ];
                networking.firewall.interfaces.eth2.allowedTCPPorts = [
                  fixture.settings.nodePort
                  6443
                  22
                  8443
                ];
                networking.firewall.trustedInterfaces = [
                  "cni0"
                  "flannel.1"
                ];
                # The test underlay models the Internet, not an authorized LAN.
                networking.nftables.tables.fixture-underlay = {
                  family = "inet";
                  content = ''
                    chain forward {
                      type filter hook forward priority -110; policy accept;
                      iifname "eth1" drop
                    }
                  '';
                };
                services.openssh = {
                  enable = true;
                  openFirewall = false;
                };
                virtualisation.incus.enable = true;
                virtualisation = {
                  cores = 4;
                  memorySize = 6144;
                  diskSize = 16384;
                  vlans = lib.mkForce [
                    1
                    2
                  ];
                  # As in identity-provision-runtime: upstream images are immutable,
                  # but registry transport needs egress when running the driver.
                  restrictNetwork = false;
                };
                systemd.tmpfiles.rules = [
                  "d /srv/secrets 0700 root root -"
                  "d ${fixture.settings.identityDataPath} 0700 1000 1000 -"
                ];
                boot.kernelModules = [
                  "nfnetlink_queue"
                  "nft_queue"
                ];
                services.k3s = {
                  enable = true;
                  role = "server";
                  package = k3s;
                  disable = [
                    "traefik"
                    "metrics-server"
                    "local-storage"
                    "servicelb"
                  ];
                  images = [ k3s.airgap-images ] ++ fixture.images;
                  extraFlags = [
                    "--node-ip=10.1.0.10"
                    "--flannel-iface=eth2"
                    "--disable-network-policy"
                  ];
                  extraKubeProxyConfig = self.nixosConfigurations.compute-1.config.services.k3s.extraKubeProxyConfig;
                };
              };
              relay = {
                imports = [
                  (network "10.0.0.11")
                  (tailnet.client "10.0.0.13")
                  (role "relay" { })
                ];
                virtualisation = {
                  cores = 1;
                  memorySize = 384;
                };
                systemd.tmpfiles.rules = [ "d /srv/secrets 0700 root root -" ];
                systemd.services.haproxy.wantedBy = lib.mkForce [ ];
              };
              client = {
                imports = [ (network "10.0.0.12") ];
                virtualisation = {
                  cores = 2;
                  memorySize = 2048;
                  vlans = lib.mkForce [
                    1
                    2
                  ];
                };
                networking.interfaces.eth2.ipv4.addresses = [
                  {
                    address = "10.1.0.12";
                    prefixLength = 24;
                  }
                ];
                networking.hosts."127.0.0.1" = fixture.settings.hostnames ++ [ "origin.test" ];
                environment.systemPackages = [
                  pkgs.chromium
                  pkgs.nssTools
                  pkgs.socat
                  (pkgs.python3.withPackages (ps: [ ps.playwright ]))
                ];
              };
              control = tailnet.control "10.0.0.13";
            };
            testScript = ''
              import json
              settings = json.load(open("${settings}"))
              exec(compile(open("${./_public-entry-runtime/test.py}").read(), "public-entry-runtime/test.py", "exec"))
            '';
          }).overrideTestDerivation
            (_: {
              __noChroot = true;
            });
      in
      {
        legacyPackages.public-edge-runtime-test = test;
        checks.public-edge-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-public-edge-runtime";
          };
        };
      }
    );
}
