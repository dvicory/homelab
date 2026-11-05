{ den, lib, inputs, ... }: {
  den.aspects.disk.impermanence = {
    includes = [
      den.aspects.core."persist-collector"
    ];

    persist = [
      { directories = [ "/var/log" "/var/lib/nixos" "/var/lib/systemd" ]; }
      { files = [
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
      ]; }
    ];

    nixos = { host, config, pkgs, ... }: let
      poolName = host.zfs.rootPool.name or null;
      source = inputs.nixpkgs.legacyPackages.${host.system}.applyPatches {
        name = "impermanence-systemd-initrd-source";
        src = inputs.impermanence.outPath;
        patches = [ ./impermanence-systemd-initrd.patch ];
        # Preserve the fork's mount requirements; remove only scripted initrd.
        outputHashMode = "recursive";
        outputHash = "sha256-4S8Txz69yLaUZmGppmnnPsllH3iuu8ImgQ/XNrBf898=";
      };
    in {
      imports = [ "${source}/nixos.nix" ];

      config = {
        fileSystems."/persist".neededForBoot = true;

        environment.persistence."/persist".files = [
          "/etc/machine-id"
        ];

      }
      // lib.optionalAttrs (host.hasAspect den.aspects.disk.zfs) {
        boot.initrd = lib.mkIf config.boot.initrd.enable {
          systemd.storePaths = [ inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.initrdZfsRollback ];

          systemd.services.initrd-zfs-rollback = {
            description = "ZFS rollback for impermanence";
            after = [ "zfs-import-${poolName}.service" ];
            before = [ "sysroot.mount" "initrd-switch-root.target" ];
            wantedBy = [ "initrd.target" ];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.initrdZfsRollback}/bin/initrd-zfs-rollback";
              StandardOutput = "journal+console";
            };

            environment.INITRD_POOL_NAME = poolName;
          };
        };
      };
    };
  };
}
