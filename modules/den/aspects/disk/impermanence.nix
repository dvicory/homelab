{ den, lib, inputs, ... }: {
  den.aspects.disk.impermanence = { host, ... }: {
    includes = [
      den.aspects."core/persist-collector"
    ];

    persist = [
      { directories = [ "/var/log" "/var/lib/nixos" "/var/lib/systemd" ]; }
      { files = [ "/etc/machine-id" ]; }
    ];

    nixos = { config, pkgs, ... }: let
      poolName = host.zfs.rootPool.name or null;
    in {
      imports = [ inputs.impermanence.nixosModules.impermanence ];

      # TODO: hasAspect den.aspects.disk.zfs — see zfs.nix for details.
      config = lib.mkIf (host.zfs.rootPool != null) {
        fileSystems."/persist".neededForBoot = true;

        services.openssh = {
          hostKeys = lib.mkForce [ ];
          extraConfig = lib.mkAfter ''
            HostKey /persist/etc/ssh/ssh_host_ed25519_key
          '';
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
