{ lib, ... }:
{
  flake.modules.nixos.profiles-hypervisor =
    { config, pkgs, ... }:
    {
      virtualisation.incus = {
        enable = true;
        package = pkgs.incus;

        ui.enable = true;
        ui.package = pkgs.incus-ui-canonical;

        preseed.config."core.https_address" = ":8443";
      };

      # TODO: upstream this? https://github.com/lxc/incus/issues/1942
      # recommended to be 330s to allow for incus to shutdown
      systemd.services.incus.serviceConfig.TimeoutStopSecond = lib.mkForce "330s";

      networking.firewall.allowedTCPPorts = [ 8443 ];

      dlab.impermanence.additionalDirectories = [
        { directory = "/var/lib/incus"; }
      ];
    };
}
