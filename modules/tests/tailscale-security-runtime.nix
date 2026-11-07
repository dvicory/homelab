{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        old = (import ./_security-baseline.nix { inherit system; }).tailscale;
        selected = inputs.self.nixosConfigurations.hvn-hyp1.config.services.tailscale.package;
        certificates =
          pkgs.runCommand "tailscale-runtime-certificates"
            {
              nativeBuildInputs = [ pkgs.openssl ];
            }
            ''
              mkdir -p "$out"
              openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
                -keyout "$out/key.pem" -out "$out/cert.pem" \
                -subj '/CN=headscale' -addext 'subjectAltName=DNS:headscale'
            '';
        isolated = {
          system.stateVersion = "26.05";
          virtualisation = {
            cores = 1;
            memorySize = 768;
            vlans = [ 1 ];
            restrictNetwork = true;
          };
        };
        peer = name: {
          imports = [ isolated ];
          services.tailscale = {
            enable = true;
            package = old;
            openFirewall = true;
            disableUpstreamLogging = true;
          };
          networking.nftables.enable = true;
          networking.firewall.checkReversePath = "loose";
          networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8000 ];
          security.pki.certificateFiles = [ "${certificates}/cert.pem" ];
          environment.systemPackages = [
            pkgs.curl
            pkgs.jq
          ];
          specialisation.security-update.configuration.services.tailscale.package = lib.mkForce selected;
          systemd.services.tailscaled.serviceConfig = {
            Environment = [ "TS_DEBUG_FIREWALL_MODE=nftables" ];
            TimeoutStartSec = 60;
            TimeoutStopSec = 60;
          };
          services.nginx = {
            enable = true;
            virtualHosts.fixture = {
              listen = [
                {
                  addr = "0.0.0.0";
                  port = 8000;
                }
              ];
              locations."/marker".return = "200 ${name}-vpn-marker";
            };
          };
        };
        test = pkgs.testers.runNixOSTest {
          name = "tailscale-security-runtime";
          globalTimeout = 20 * 60;
          requiredFeatures.kvm = true;
          nodes = {
            peer1 = peer "peer1";
            peer2 = peer "peer2";
            headscale = {
              imports = [ isolated ];
              virtualisation.memorySize = lib.mkForce 1024;
              services.headscale = {
                enable = true;
                port = 8080;
                settings = {
                  server_url = "https://headscale";
                  derp = {
                    server = {
                      enabled = true;
                      region_id = 999;
                      stun_listen_addr = "0.0.0.0:3478";
                    };
                    urls = [ ];
                    auto_update_enabled = false;
                  };
                  dns = {
                    base_domain = "tailnet";
                    override_local_dns = false;
                  };
                };
              };
              services.nginx = {
                enable = true;
                virtualHosts.headscale = {
                  addSSL = true;
                  sslCertificate = "${certificates}/cert.pem";
                  sslCertificateKey = "${certificates}/key.pem";
                  locations."/" = {
                    proxyPass = "http://127.0.0.1:8080";
                    proxyWebsockets = true;
                  };
                };
              };
              networking.firewall = {
                allowedTCPPorts = [ 443 ];
                allowedUDPPorts = [ 3478 ];
              };
              environment.systemPackages = [ pkgs.headscale ];
            };
          };
          testScript = ''
            old_package = "${old}"
            old_version = "${old.version}"
            selected_package = "${selected}"
            ${builtins.readFile ./tailscale-security-runtime.py}
          '';
        };
      in
      {
        checks.tailscale-security-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-tailscale-runtime";
          };
        };
      }
    );
}
