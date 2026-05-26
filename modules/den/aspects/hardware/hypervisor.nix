{ lib, ... }: {
  den.aspects.hardware.hypervisor = {
    persist = [
      { directories = [ "/var/lib/incus" ]; user = "incus"; group = "incus"; }
    ];

    nixos = { pkgs, ... }: {
      virtualisation.incus = {
        enable = true;
        package = pkgs.incus;
        ui.enable = true;
        ui.package = pkgs.incus-ui-canonical;
        preseed.config."core.https_address" = ":8443";
      };

      systemd.services.incus.serviceConfig.TimeoutStopSecond = lib.mkForce "330s";

      networking.firewall.allowedTCPPorts = [ 8443 ];
    };
  };
}
