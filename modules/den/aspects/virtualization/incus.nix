{ lib, ... }: {
  den.aspects.virtualization.incus = {
    persist = [
      {
        directories = [ "/var/lib/incus" ];
        user = "incus";
        group = "incus";
      }
    ];

    nixos =
      { config, pkgs, ... }:
      let
        stateDirectory = "/var/lib/incus";
        # Directories impermanence binds from persistent storage, if any.
        persisted = lib.concatMap (persistence: lib.catAttrs "dirPath" persistence.directories) (
          lib.filter (persistence: persistence.enable or true) (
            lib.attrValues (config.environment.persistence or { })
          )
        );
        # Binds that provide the state directory: itself or a parent.
        covering = lib.filter (
          path: path == stateDirectory || lib.hasPrefix "${lib.removeSuffix "/" path}/" stateDirectory
        ) persisted;
        inside = lib.filter (lib.hasPrefix "${stateDirectory}/") persisted;
      in
      {
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
                  # Concurrent completion generators otherwise race to create
                  # config.yml; --force-local skips that first-run write.
                  postInstall =
                    builtins.replaceStrings
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

        # A bind mount that provides /var/lib/incus, such as impermanence's
        # persistence bind, is a mount peer of the filesystem it came from:
        # every mount Incus makes below /var/lib/incus also appears below the
        # persistent copy. Linux keeps such a copy while it has a child mount,
        # so a disk device whose source contains a mount leaves a busy copy
        # behind and the instance cannot start again. Before Incus starts, the
        # script finds these copies in the kernel mount table, makes the bind
        # private, removes the copies and checks the result. It changes nothing
        # where /var/lib/incus is not shared with another view.
        systemd.services.incus-mount-isolation = {
          description = "Keep Incus runtime mounts out of other views of /var/lib/incus";
          wantedBy = [
            "multi-user.target"
            "incus.service"
          ];
          # incus.socket starts before basic.target, so default dependencies
          # would order this unit after it and form a cycle.
          after = [ "sysinit.target" ];
          before = [
            "incus.service"
            "incus.socket"
            "shutdown.target"
          ];
          conflicts = [ "shutdown.target" ];
          unitConfig = {
            DefaultDependencies = false;
            RequiresMountsFor = stateDirectory;
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${
              pkgs.writers.writePython3Bin "incus-mount-isolation" {
                flakeIgnore = [
                  "E501"
                  "W503"
                ];
                makeWrapperArgs = [
                  "--prefix"
                  "PATH"
                  ":"
                  (lib.makeBinPath [ pkgs.util-linux ])
                ];
              } ./incus-mount-isolation.py
            }/bin/incus-mount-isolation ${stateDirectory}";
          };
        };

        # The script handles one bind that provides /var/lib/incus. A second,
        # nested bind hides copies below the inner bind, and a bind below
        # /var/lib/incus is a separate peer the script does not look at.
        assertions = [
          {
            assertion = lib.length covering <= 1;
            message = "incus-mount-isolation handles one persistence bind that provides ${stateDirectory}, but impermanence binds ${lib.concatStringsSep " and " covering}.";
          }
          {
            assertion = inside == [ ];
            message = "incus-mount-isolation does not isolate persistence binds below ${stateDirectory}, but impermanence binds ${lib.concatStringsSep ", " inside}.";
          }
        ];

        networking.firewall.allowedTCPPorts = [ 8443 ];
      };
  };
}
