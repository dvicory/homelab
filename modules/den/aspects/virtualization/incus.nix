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
        # The persistence root that binds /var/lib/incus, if impermanence does.
        incusPersistence = lib.findFirst (
          persistence: lib.any (entry: entry.directory == "/var/lib/incus") persistence.directories
        ) null (lib.attrValues (lib.attrByPath [ "environment" "persistence" ] { } config));
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

        # Impermanence binds /var/lib/incus from its persistent copy, which makes
        # the two mount peers: every mount Incus makes below /var/lib/incus also
        # appears below the persistent copy. Linux keeps such a copy while it has
        # a child mount, so a disk device whose source contains a mount leaves a
        # busy copy behind and the instance cannot start again. Make
        # /var/lib/incus private, so nothing propagates in either direction, and
        # drop copies earlier runs left. Private comes first: unmounting a copy
        # propagates to the peers and slaves of its parent mount.
        systemd.services.incus-mount-isolation = lib.mkIf (incusPersistence != null) {
          description = "Keep Incus runtime mounts out of the persistent store view";
          wantedBy = [
            "multi-user.target"
            "incus.service"
          ];
          before = [
            "incus.service"
            "incus.socket"
          ];
          after = [ "var-lib-incus.mount" ];
          unitConfig.ConditionPathIsMountPoint = "/var/lib/incus";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe (
              pkgs.writeShellApplication {
                name = "incus-mount-isolation";
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.gnugrep
                  pkgs.util-linux
                ];
                text = ''
                  persist=${lib.escapeShellArg "${incusPersistence.persistentStoragePath}/var/lib/incus"}
                  mount --make-private /var/lib/incus
                  mapfile -t targets < <(findmnt --raw --noheadings --output TARGET | grep -F "$persist/" | sort)
                  last=""
                  for target in "''${targets[@]}"; do
                    [[ "$target" == "$persist"/* ]] || continue
                    # Removing a copy removes everything mounted below it.
                    if [ -n "$last" ] && [[ "$target" == "$last"/* ]]; then
                      continue
                    fi
                    last=$target
                    # Private first, so the unmount cannot propagate to the
                    # live mounts the copy mirrors. Lazy, because an open file
                    # can hold the copy; the live mount stays in place.
                    mount --make-rprivate "$target"
                    umount --recursive --lazy "$target"
                    echo "removed propagated copy $target"
                  done
                '';
              }
            );
          };
        };

        networking.firewall.allowedTCPPorts = [ 8443 ];
      };
  };
}
