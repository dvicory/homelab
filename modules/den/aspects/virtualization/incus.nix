{ lib, ... }: {
  den.aspects.virtualization.incus = {
    persist = [
      { directories = [ "/var/lib/incus" ]; user = "incus"; group = "incus"; }
    ];

    nixos = { pkgs, ... }: {
      virtualisation.incus = {
        enable = true;
        # Incus 7.4 rejects adjacent raw ID maps; remove with the upstream fix.
        package = pkgs.incus.overrideAttrs (
          old:
          let
            patchedSrc = pkgs.applyPatches {
              inherit (old) src;
              patches = [ ./incus-adjacent-idmap.patch ];
            };
          in
          {
            src = patchedSrc;
            passthru = old.passthru // {
              client = old.passthru.client.overrideAttrs (client: {
                src = patchedSrc;
                postInstall = builtins.replaceStrings
                  [ "$out/bin/incus completion" ]
                  [ "$out/bin/incus --force-local completion" ]
                  client.postInstall;
              });
            };
          }
        );
        ui.enable = true;
        ui.package = pkgs.incus-ui-canonical;
        preseed.config."core.https_address" = ":8443";
      };

      systemd.services.incus.serviceConfig.TimeoutStopSecond = lib.mkForce "330s";

      networking.firewall.allowedTCPPorts = [ 8443 ];
    };
  };
}
