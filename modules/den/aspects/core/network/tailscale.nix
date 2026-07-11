# Tailscale mesh VPN. No auth key is used — authenticate the node
# interactively after the first deploy with `tailscale up`. The daemon
# runs in nftables mode (the host already enables nftables via the
# networking aspect); checkReversePath is loosened so exit-node /
# subnet-router traffic isn't dropped by the host firewall.
{ lib, ... }: {
  den.aspects.core.network.tailscale = {
    nixos = { config, ... }: {
      services.tailscale = {
        enable = true;
        openFirewall = true;
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
