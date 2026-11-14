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
  den.aspects.core.network.tailscale = {
    firewall = { config, ... }: [
      {
        networking.firewall = {
          checkReversePath = "loose";
          allowedUDPPorts = [ config.services.tailscale.port ];
        };
      }
    ];

    nixos =
      {
        config,
        pkgs,
        ...
      }:
      let
        secretExists = builtins.pathExists authKeyFile;
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
          # Retain the supported release until ordinary Nixpkgs catches up.
          package = pkgs.tailscale.overrideAttrs (
            final: old:
            let
              version = "1.104.5";
            in
            assert lib.assertMsg (lib.versionAtLeast version old.version)
              "Tailscale ${old.version} supersedes the ${version} release override; remove the release override and refresh its dependency patch.";
            {
              inherit version;
              src = pkgs.fetchFromGitHub {
                owner = "tailscale";
                repo = "tailscale";
                tag = "v${final.version}";
                hash = "sha256-aq4pBe75wNRFDEa3kSDa/pBLsZws5mOUOjHDUycpmXM=";
              };
              # Keep actual Go symbols available to the binary auditor.
              ldflags = lib.remove "-s" old.ldflags;
              dontStrip = true;
              # GO-2026-6865 reaches huff0/fse through control-map zstd decoding.
              patches = (old.patches or [ ]) ++ [ ./tailscale-go-security.patch ];
              vendorHash = "sha256-l4khfLtoDLrsGm3F8xcgshKe44MdDvlP2P/OzZfCivI=";
            }
          );
          # The service-owned firewall fragment admits only the transport port.
          openFirewall = false;
          authKeyFile = lib.mkIf secretExists config.age.secrets.tailscale-auth-key.path;
        };

        systemd.services.tailscaled.serviceConfig.Environment = [
          "TS_DEBUG_FIREWALL_MODE=nftables"
        ];
      };

    persist = [ "/var/lib/tailscale" ];
  };
}
