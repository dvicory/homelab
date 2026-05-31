{ den, lib, inputs, ... }: {
  den.aspects.disk.impermanence = {
    includes = [
      den.aspects.core."persist-collector"
    ];

    persist = [
      { directories = [ "/var/log" "/var/lib/nixos" "/var/lib/systemd" ]; }
      { files = [ "/etc/machine-id" ]; }
    ];

    nixos = { host, config, pkgs, ... }: let
      poolName = host.zfs.rootPool.name or null;
    in {
      imports = [ inputs.impermanence.nixosModules.impermanence ];

      config = {
        fileSystems."/persist".neededForBoot = true;

        # DynamicUser services (e.g. crowdsec) require /var/lib/private
        # to be mode 0700. Without this, systemd's StateDirectory setup
        # fails with: "Directory /var/lib/private already exists, but
        # has mode 0755 that is too permissive (0700 was requested),
        # refusing."
        #
        # Root cause: impermanence's persistence-run-create-directories
        # creates parent directories for mount targets with default 0755,
        # stomping any previously-corrected mode. Known incompatibility:
        #   https://github.com/nix-community/impermanence/issues/254
        #
        # We use a oneshot service rather than systemd-tmpfiles because
        # the tmpfiles `d` type skips existing directories (only creates,
        # doesn't fix mode), while `z` would recursively modify children.
        # A oneshot runs at both boot and activation, after impermanence
        # scripts have finished but before any services start.
        systemd.services.fix-private-var-lib = {
          description = "Fix /var/lib/private mode for DynamicUser compatibility";
          after = [ "local-fs.target" ];
          before = [ "multi-user.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/chmod 0700 /var/lib/private";
          };
        };

        services.openssh = {
          hostKeys = lib.mkForce [ ];
          extraConfig = lib.mkAfter ''
            HostKey /persist/etc/ssh/ssh_host_ed25519_key
          '';
        };
      }
      // lib.optionalAttrs (host.hasAspect den.aspects.disk.zfs) {
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
