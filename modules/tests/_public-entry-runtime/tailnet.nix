# Disposable control/enrollment only; application and packet drivers stay separate.
{ pkgs, lib }:
let
  tls = pkgs.runCommand "fixture-tailnet-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -subj /CN=headscale -addext subjectAltName=DNS:headscale \
      -addext basicConstraints=critical,CA:TRUE \
      -keyout $out/key.pem -out $out/cert.pem
  '';
  policy = pkgs.writeText "fixture-tailnet-policy.json" (
    builtins.toJSON {
      # Deliberately hostile authenticated peers: nftables, not control ACLs,
      # must enforce every denied target in these fixtures.
      acls = [
        {
          action = "accept";
          src = [ "*" ];
          dst = [ "*:*" ];
        }
      ];
    }
  );
in
{
  client = controlAddress: { config, ... }: {
    networking.hosts.${controlAddress} = [ "headscale" ];
    security.pki.certificateFiles = [ "${tls}/cert.pem" ];
    services.tailscale = {
      enable = true;
      disableUpstreamLogging = true;
      extraUpFlags = [ "--login-server=https://headscale" ];
    };
    # The driver stages separate single-use credentials and enrolls serially.
    systemd.services.tailscaled-autoconnect.wantedBy = lib.mkForce [ ];
    systemd.services.tailscaled-set = lib.mkIf (config.services.tailscale.extraSetFlags != [ ]) {
      wantedBy = lib.mkForce [ ];
    };
  };
  control = address: { ... }: {
    system.stateVersion = "26.05";
    virtualisation.vlans = [ 1 ];
    virtualisation.memorySize = 768;
    networking.useDHCP = false;
    networking.interfaces.eth1.ipv4.addresses = [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
    networking.firewall.allowedTCPPorts = [ 443 ];
    networking.firewall.allowedUDPPorts = [ 3478 ];
    services.headscale = {
      enable = true;
      settings = {
        server_url = "https://headscale";
        prefixes = {
          v4 = "100.64.0.0/24";
          v6 = "fd7a:115c:a1e0::/48";
          allocation = "sequential";
        };
        policy = {
          mode = "file";
          path = policy;
        };
        derp = {
          server = {
            enabled = true;
            region_id = 999;
            region_code = "fixture";
            region_name = "Disposable fixture";
            stun_listen_addr = "0.0.0.0:3478";
          };
          urls = [ ];
          paths = [ ];
          auto_update_enabled = false;
        };
        dns = {
          base_domain = "fixture.tailnet";
          override_local_dns = false;
          magic_dns = false;
        };
      };
    };
    services.nginx = {
      enable = true;
      virtualHosts.headscale = {
        forceSSL = true;
        sslCertificate = "${tls}/cert.pem";
        sslCertificateKey = "${tls}/key.pem";
        locations."/" = {
          proxyPass = "http://127.0.0.1:8080";
          proxyWebsockets = true;
        };
      };
    };
    environment.systemPackages = [
      pkgs.headscale
      pkgs.jq
      (pkgs.writeShellScriptBin "fixture-enrollment" ''
        set -eu
        umask 077
        role="$1"
        case "$role" in origin|relay|host|private) ;; *) exit 1;; esac
        mkdir -p /run/fixture-tailnet
        case "$role" in origin|relay) tag="public-$role";; *) tag="$role";; esac
        headscale preauthkeys create --tags "tag:$tag" --expiration 30m --output json > "/run/fixture-tailnet/$role.json"
        ${pkgs.jq}/bin/jq -er '.key' "/run/fixture-tailnet/$role.json" > "/run/fixture-tailnet/$role.key"
      '')
    ];
  };
}
