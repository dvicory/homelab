# Impermanence Profile
#
# This profile handles core system persistence that every system needs:
# - /var/log: System logs and journald history
# - /var/lib/nixos: User/group ID mappings and declarative user state
# - /var/lib/systemd: Timer stamps, time sync state, user lingering
# - /etc/machine-id: Stable system identity
#
# Service-specific persistence should be handled in their respective modules.
{ self, inputs, ... }:
{
  flake-file.inputs = {
    impermanence.url = "github:dvicory/impermanence/systemd-requires";
  };

  flake.modules.nixos.profiles-impermanence =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.dlab.impermanence;
      hostCfg = config.dlab.hostCfg;
      inherit (self.packages.${pkgs.system}) initrdZfsRollback;
    in
    {
      imports = [ inputs.impermanence.nixosModules.impermanence ];

      options.dlab.impermanence = {
        enable = lib.mkEnableOption "Enable proper system persistence for Skarabox";

        persistPath = lib.mkOption {
          type = lib.types.str;
          default = "/persist";
          description = "Base path for persistent storage";
        };

        additionalDirectories = lib.mkOption {
          type = lib.types.listOf (lib.types.either lib.types.str lib.types.raw);
          default = [ ];
          description = "Additional directories to persist beyond the defaults";
        };

        additionalFiles = lib.mkOption {
          type = lib.types.listOf (lib.types.either lib.types.str lib.types.raw);
          default = [ ];
          description = "Additional files to persist beyond the defaults";
        };
      };

      config = lib.mkIf cfg.enable {
        fileSystems.${cfg.persistPath} = {
          # Let other modules configure non-impermanence aspects of the persist path
          # We must set neededForBoot to satisfy impermanence's assertion
          neededForBoot = true;
        };

        # Core impermanence configuration
        environment.persistence.${cfg.persistPath} = {
          # hideMounts = true;

          directories = [
            # Essential system state (required for every system)
            "/var/log" # System logs (journalctl history)
            "/var/lib/nixos" # NixOS state (UID/GID maps, declarative users/groups)
            "/var/lib/systemd" # systemd state (timers, timesync, linger)
          ]
          ++ cfg.additionalDirectories;

          files = [
            # Essential system identity
            "/etc/machine-id" # Stable system identity for journal continuity
          ]
          ++ cfg.additionalFiles;
        };

        boot.initrd = lib.mkIf config.boot.initrd.systemd.enable {
          systemd.storePaths = [ initrdZfsRollback ];

          systemd.services.initrd-zfs-rollback = {
            description = "ZFS rollback for impermanence";

            # Run AFTER the pool is imported but BEFORE the rootfs is mounted
            after = [ "zfs-import-${hostCfg.rootPool.name}.service" ];
            before = [
              "sysroot.mount"
              "initrd-switch-root.target"
            ];
            wantedBy = [ "initrd.target" ];

            # Don't use requiredBy to avoid circular dependency
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${initrdZfsRollback}/bin/initrd-zfs-rollback";
              StandardOutput = "journal+console";
            };
            environment = {
              INITRD_POOL_NAME = hostCfg.rootPool.name;
            };
          };
        };

        warnings = lib.optional (
          !builtins.pathExists "${cfg.persistPath}"
        ) "Persistence path ${cfg.persistPath} may not exist - ensure it's created before first boot";
      };
    };
}
