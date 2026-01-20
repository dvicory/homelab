/**
  # MergerFS Module

  Provides a declarative API for setting up mergerfs pools that combine multiple
  mount points into a single unified filesystem.

  ## Features

  - Automatic mounting at boot and on deploy
  - Automatic branch updates via path unit watching
  - Support for additional explicit dependencies
  - Sensible defaults (allow_other enabled by default)
  - Automatic boot.supportedFilesystems configuration
  - Validates that all branches are properly mounted

  ## Usage

  ```nix
  dlab.storage.mergerfs."/mnt/storage" = {
    branches = [
      "/mnt/storage-clear/media1"
      "/mnt/storage-clear/media2"
    ];
    options = [ "allow_other" ];
    depends = [ ];
  };
  ```
*/
{ lib, ... }:
{
  flake.modules.nixos.nixos = { config, pkgs, ... }: let 
    inherit (lib) mkOption mkIf mkMerge types;
    cfg = config.dlab.storage.mergerfs;
    
    # Helper to escape systemd path names
    escapeSystemdPath = path: 
      (lib.strings.sanitizeDerivationName (builtins.substring 1 (-1) path));

  in
  {
    options.dlab.storage.mergerfs = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          branches = mkOption {
            type = types.listOf types.str;
            description = ''
              List of mount paths to merge. These should be absolute paths that
              are already mounted in the system (via fileSystems).
            '';
            example = [ "/mnt/storage-clear/media1" "/mnt/storage-clear/media2" ];
          };

          options = mkOption {
            type = types.listOf types.str;
            default = [
              "allow_other"
              # TODO: passthrough support added in 2.41.0
              # "passthrough.io=rw"
              # "passthrough.max-stack-depth=3"
            ];
            description = ''
              MergerFS mount options. Defaults include passthrough.io=rw for better I/O performance.
            '';
            example = [
              "cache.files=full"
            ];
          };

          depends = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              Additional mount dependencies beyond the branches.

              Use this for parity drives, network mounts, or systemd targets
              that should be available before mounting this mergerfs pool.
            '';
            example = [ "/mnt/parity/disk1" ];
          };
        };
      });
      default = { };
      description = ''
        MergerFS pool definitions. Each attribute is a mount path that will be
        created as a fuse.mergerfs mount combining the specified branches.
      '';
    };

    config = mkIf (cfg != { }) (mkMerge [
      # Ensure required packages and boot support
      {
        environment.systemPackages = [ pkgs.mergerfs pkgs.attr ];
        boot.supportedFilesystems = [ "fuse" "fuse.mergerfs" ];
      }

      # Write branch configurations to /etc so they're available at boot and persist
      {
        environment.etc = lib.mapAttrs' (path: poolCfg:
          let
            escapedPath = escapeSystemdPath path;
            branchString = lib.concatStringsSep ":" poolCfg.branches;
            optionsString = lib.concatStringsSep "," poolCfg.options;
          in
          lib.nameValuePair "mergerfs/${escapedPath}.conf" {
            text = ''
              PATH=${path}
              BRANCHES=${branchString}
              OPTIONS=${optionsString}
            '';
          }
        ) cfg;
      }

      # Create systemd services for each mergerfs pool
      {
        systemd.services = lib.mapAttrs' (path: poolCfg:
          let
            escapedPath = escapeSystemdPath path;
          in
          lib.nameValuePair "mergerfs-mnt-${escapedPath}" {
            description = "MergerFS pool at ${path}";
            wantedBy = [ "multi-user.target" ];
            after = poolCfg.depends ++ [ "local-fs.target" ];
            requires = poolCfg.depends;

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              EnvironmentFile = "/etc/mergerfs/${escapedPath}.conf";
              ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.util-linux}/bin/mount -t fuse.mergerfs -o \$OPTIONS \$BRANCHES \$PATH'";
              ExecReload = "${pkgs.bash}/bin/bash -c '${pkgs.attr}/bin/setfattr -n user.mergerfs.branches -v \"\$BRANCHES\" \"\$PATH/.mergerfs\"'";
              ExecStop = "${pkgs.bash}/bin/bash -c '${pkgs.util-linux}/bin/umount \"\$PATH\"'";
            };
          }
        ) cfg;
      }

      # Path units - one per pool to watch for branch config changes
      {
        systemd.paths = lib.mapAttrs' (path: poolCfg:
          let
            escapedPath = escapeSystemdPath path;
          in
          lib.nameValuePair "mergerfs-branch-${escapedPath}" {
            description = "Watch MergerFS branches for ${path}";
            pathConfig = {
              PathChanged = "/etc/mergerfs/${escapedPath}.conf";
              Unit = "mergerfs-branch-reload-${escapedPath}.service";
            };
            wantedBy = [ "multi-user.target" ];
            after = [ "mergerfs-mnt-${escapedPath}.service" ];
          }
        ) cfg;
      }

      # Reload services - one per pool triggered by its path unit
      {
        systemd.services = lib.mapAttrs' (path: poolCfg:
          let
            escapedPath = escapeSystemdPath path;
          in
          lib.nameValuePair "mergerfs-branch-reload-${escapedPath}" {
            description = "Reload MergerFS branches for ${path}";
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              EnvironmentFile = "/etc/mergerfs/${escapedPath}.conf";
              ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.attr}/bin/setfattr -n user.mergerfs.branches -v \"\$BRANCHES\" \"\$PATH/.mergerfs\"'";
            };
          }
        ) cfg;
      }

      # Activation script to trigger reload when conf files change
      {
        system.activationScripts.mergerfsReload = lib.stringAfter [ "etc" ] (
          let
            reloadCommands = lib.concatStringsSep "\n" (
              lib.mapAttrsToList (path: poolCfg:
                let
                  escapedPath = escapeSystemdPath path;
                in
                ''echo "Triggering reload for mergerfs pool: ${path}"
                  ${pkgs.systemd}/bin/systemctl --no-block start mergerfs-branch-reload-${escapedPath}.service
                  echo "Reload service start result: $?"''
              ) cfg
            );
          in
          if cfg != { } then ''
            echo "=== MergerFS Activation Script ==="
            # Reload mergerfs pools when configuration changes
            ${reloadCommands}
            echo "=== End MergerFS Activation Script ==="
          '' else ""
        );
      }

      # Create mount points
      {
        systemd.tmpfiles.rules = lib.mapAttrsToList (path: poolCfg:
          "d ${path} 0755 root root -"
        ) cfg;
      }

      # Validate that all branches are defined in fileSystems
      {
        assertions = lib.flatten (
          lib.mapAttrsToList
            (path: poolCfg:
              lib.map
                (branch:
                  {
                    assertion = config.fileSystems ? ${branch};
                    message = ''
                      MergerFS pool at ${path} references branch ${branch}
                      which is not defined in fileSystems. Branches must be
                      existing mount points in the system configuration.
                    '';
                  }
                )
                poolCfg.branches
            )
            cfg
        );
      }
    ]);
  };
}
