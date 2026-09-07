{ lib, ... }: {
  den.aspects.virtualization.incus = {
    persist = [
      {
        directories = [ "/var/lib/incus" ];
        user = "incus";
        group = "incus";
      }
    ];

    nixos = { pkgs, ... }: {
      virtualisation.incus = {
        enable = true;
        # Incus 7.4 rejects adjacent raw ID maps. Remove when upstream fixes
        # HostIDsIntersect's exclusive upper-bound calculation.
        package = pkgs.incus.overrideAttrs (old: {
          src = pkgs.applyPatches {
            inherit (old) src;
            patches = [ ./incus-adjacent-idmap.patch ];
          };
        });
        ui.enable = true;
        ui.package = pkgs.incus-ui-canonical;
        preseed.config."core.https_address" = ":8443";
      };

      systemd.services.incus.serviceConfig.TimeoutStopSecond = lib.mkForce "330s";

      networking.firewall.allowedTCPPorts = [ 8443 ];
    };
  };
}
