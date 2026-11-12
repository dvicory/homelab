{ config, lib, ... }:
{
  config = lib.mkIf config.networking.nftables.enable {
    # Rules live in the kernel. Keep them and the saved ownership record until
    # the next atomic start/reload replaces them, including after service stop.
    systemd.services.nftables.serviceConfig.ExecStop = lib.mkForce [ ];
  };
}
