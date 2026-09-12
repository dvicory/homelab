{ lib, ... }:
let
  mergerfs = import ./_mergerfs.nix { inherit lib; };
in
{
  den.aspects.services.mergerfs = {
    settings.pools = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            branches = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Mount paths to merge";
            };
            options = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "allow_other" ];
            };
            depends = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
          };
        }
      );
      default = { };
      description = "MergerFS pool definitions";
    };

    nixos =
      {
        host,
        config,
        pkgs,
        lib,
        ...
      }:
      let
        cfg = host.settings.services.mergerfs.pools or { };
        escapeSystemdPath = path: lib.strings.sanitizeDerivationName (builtins.substring 1 (-1) path);
      in
      lib.mkIf (cfg != { }) (
        lib.mkMerge [
          {
            environment.systemPackages = [
              pkgs.mergerfs
            ];
            boot.supportedFilesystems = [
              "fuse"
              "fuse.mergerfs"
            ];
            assertions = [
              {
                # Before 2.42.0 mergerfs resolved entitlements from the host group
                # database instead of the process, so a workload holding a storage
                # capability as a supplemental group had its writes refused with no
                # useful error. Measured on 2.40.2 and 2.42.0.
                assertion = lib.versionAtLeast pkgs.mergerfs.version "2.42.0";
                message = "services.mergerfs: mergerfs ${pkgs.mergerfs.version} cannot authorize supplemental storage groups; 2.42.0 or later is required";
              }
            ];
          }

          {
            environment.etc = lib.mapAttrs' (
              path: poolCfg:
              let
                escapedPath = escapeSystemdPath path;
                branchString = lib.concatStringsSep ":" poolCfg.branches;
                optionsString = lib.concatStringsSep "," (poolCfg.options or [ "allow_other" ]);
              in
              lib.nameValuePair "mergerfs/${escapedPath}.conf" {
                text = ''
                  MOUNTPOINT=${path}
                  BRANCHES=${branchString}
                  OPTIONS=${optionsString}
                '';
              }
            ) cfg;
          }

          {
            systemd.services = lib.mapAttrs' (
              path: poolCfg:
              let
                escapedPath = escapeSystemdPath path;
              in
              lib.nameValuePair "mergerfs-mnt-${escapedPath}" {
                description = "MergerFS pool at ${path}";
                wantedBy = [ "multi-user.target" ];
                after = (poolCfg.depends or [ ]) ++ [ "local-fs.target" ];
                requires = poolCfg.depends or [ ];

                # The generated EnvironmentFile is not part of the unit
                # definition, so make branch/config changes restart the pool.
                restartTriggers = [
                  config.environment.etc."mergerfs/${escapedPath}.conf".source
                ];
                path = [ pkgs.util-linux ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  EnvironmentFile = "/etc/mergerfs/${escapedPath}.conf";
                  ExecStartPre = "${pkgs.bash}/bin/bash -c ${lib.escapeShellArg (mergerfs.branchGuard poolCfg.branches)}";
                  ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.util-linux}/bin/mount -t fuse.mergerfs -o $OPTIONS $BRANCHES $MOUNTPOINT'";
                  ExecStop = "${pkgs.bash}/bin/bash -c '${pkgs.util-linux}/bin/umount \"$MOUNTPOINT\"'";
                };
              }
            ) cfg;
          }
          {
            systemd.tmpfiles.rules = lib.mapAttrsToList (
              path: poolCfg:
              # Deliberately inaccessible while unmounted: a pool that failed to
              # mount must not look like a usable empty directory.
              "d ${path} 0000 root root -"
            ) cfg;
          }
        ]
      );
  };
}
