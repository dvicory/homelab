# Tailscale mesh VPN. A single reusable auth key (shared across all hosts)
# enables headless first-boot authentication. After the first boot, the
# node identity persists in /var/lib/tailscale and the auth key is no
# longer needed. If the auth key secret is absent, falls back to
# interactive auth (`tailscale up`).
#
# To enable headless auth:
#   1. Generate a reusable auth key in the Tailscale admin console
#      (https://login.tailscale.com/admin/settings/keys)
#   2. agenix edit .secrets/shared/tailscale-auth-key.age
#      # paste the key (tskey-auth-...)
#   3. agenix rekey && git add .secrets && git commit
#   4. Redeploy — the aspect picks up the secret automatically.
{ inputs, lib, ... }:
let
  authKeyFile = inputs.self + "/.secrets/shared/tailscale-auth-key.age";
in
{
  flake-file.inputs.nixpkgs-security.url = "github:NixOS/nixpkgs/nixos-unstable";

  den.aspects.core.network.tailscale = {
    nixos =
      {
        config,
        host,
        pkgs,
        ...
      }:
      let
        secretExists = builtins.pathExists authKeyFile;
        securityPkgs = inputs.nixpkgs-security.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      in
      {
        secretRequests.tailscale-auth-key = lib.mkIf secretExists {
          provider = "agenix";
          ageFile = authKeyFile;
          mode = "0400";
          restartUnits = [ "tailscaled.service" ];
        };

        services.tailscale = {
          enable = true;
          # Package-only security pin; retain the release recipe's Go 1.27 toolchain.
          package = securityPkgs.tailscale.overrideAttrs (
            final: old: {
              version = "1.104.5";
              src = securityPkgs.fetchFromGitHub {
                owner = "tailscale";
                repo = "tailscale";
                tag = "v${final.version}";
                hash = "sha256-aq4pBe75wNRFDEa3kSDa/pBLsZws5mOUOjHDUycpmXM=";
              };
              patches = (old.patches or [ ]) ++ [ ./tailscale-go-security.patch ];
              vendorHash = "sha256-wiugBc4W0/F0HpAPaJUVWyum8g15+0rmSXV1s4U0ppQ=";
            }
          );
          openFirewall = true;
          authKeyFile = lib.mkIf secretExists config.age.secrets.tailscale-auth-key.path;
        };

        networking.firewall = {
          checkReversePath = "loose";
          allowedUDPPorts = [ config.services.tailscale.port ];
        };

        systemd.services.tailscaled.serviceConfig.Environment = [
          "TS_DEBUG_FIREWALL_MODE=nftables"
        ];
      };

    persist = [ "/var/lib/tailscale" ];
  };
}
