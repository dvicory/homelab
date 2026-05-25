{ den, lib, inputs, ... }: {
  den.aspects."disk/impermanence" = { host, ... }: {
    nixos = { config, pkgs, ... }: let
      poolName = host.zfs.rootPool.name or null;
    in {
      imports = [ inputs.impermanence.nixosModules.impermanence ];

      config = lib.mkIf (host.hasAspect den.aspects."disk/zfs") {
        fileSystems."/persist".neededForBoot = true;

        services.openssh = {
          hostKeys = lib.mkForce [ ];
          extraConfig = lib.mkAfter ''
            HostKey /persist/etc/ssh/ssh_host_ed25519_key
          '';
        };

        environment.persistence."/persist" = {
          directories = [
            "/var/log"
            "/var/lib/nixos"
            "/var/lib/systemd"
          ] ++ config.persist.directories;

          files = [ "/etc/machine-id" ];
        };

        boot.initrd = lib.mkIf config.boot.initrd.systemd.enable {
          systemd.storePaths = [ inputs.self.packages.${pkgs.system}.initrdZfsRollback ];

          systemd.services.initrd-zfs-rollback = {
            description = "ZFS rollback for impermanence";
            after = [ "zfs-import-${poolName}.service" ];
            before = [ "sysroot.mount" "initrd-switch-root.target" ];
            wantedBy = [ "initrd.target" ];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${inputs.self.packages.${pkgs.system}.initrdZfsRollback}/bin/initrd-zfs-rollback";
              StandardOutput = "journal+console";
            };

            environment.INITRD_POOL_NAME = poolName;
          };
        };
      };
    };
  };
}
