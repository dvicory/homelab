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
{ inputs, lib, ... }: let
  authKeyFile = inputs.self + "/.secrets/shared/tailscale-auth-key.age";
in {
  den.aspects.core.network.tailscale = {
    nixos = { config, host, ... }: let
      secretExists = builtins.pathExists authKeyFile;
    in {
      secretRequests.tailscale-auth-key = lib.mkIf secretExists {
        provider = "agenix";
        ageFile = authKeyFile;
        mode = "0400";
        restartUnits = [ "tailscaled.service" ];
      };

      services.tailscale = {
        enable = true;
        openFirewall = true;
        authKeyFile = lib.mkIf secretExists config.age.secrets.tailscale-auth-key.path;
      };

      networking.firewall = {
        checkReversePath = "loose";
        trustedInterfaces = [ config.services.tailscale.interfaceName ];
        allowedUDPPorts = [ config.services.tailscale.port ];
      };

      systemd.services.tailscaled.serviceConfig.Environment = [
        "TS_DEBUG_FIREWALL_MODE=nftables"
      ];
    };

    persist = [ "/var/lib/tailscale" ];
  };
}
