{ lib, ... }:
let
  mergerfs = import ./_mergerfs.nix { inherit lib; };

  branchType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.addCheck lib.types.str mergerfs.isCanonicalPath;
        description = "Mounted backing path.";
      };
      unit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Systemd unit that mounts the backing path.";
      };
      required = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether an unavailable backing path refuses the pool.";
      };
      create = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether mergerfs may place new content on this backing path.";
      };
    };
  };
in
{
  den.aspects.services.mergerfs = {
    settings.pools = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            branches = lib.mkOption {
              type = lib.types.listOf branchType;
              description = "Declared backing placements for this namespace.";
            };
            options = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [
                "allow_other"
                "category.create=epmfs"
                "moveonenospc=false"
                "statfs-ignore=nc"
                "statfs=full"
              ];
              description = "MergerFS mount options.";
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
        pkgs,
        lib,
        ...
      }:
      let
        cfg = host.settings.services.mergerfs.pools or { };
        nonCanonicalPoolPaths = mergerfs.nonCanonicalPoolPaths cfg;
        duplicatePaths = mergerfs.duplicatePaths cfg;
        requiredWithoutUnit = mergerfs.requiredWithoutUnit cfg;
        optionalCreatePaths = mergerfs.optionalCreatePaths cfg;
      in
      lib.mkIf (cfg != { }) (
        lib.mkMerge [
          {
            environment.systemPackages = [ pkgs.mergerfs ];
            boot.supportedFilesystems = [
              "fuse"
              "fuse.mergerfs"
            ];
            assertions = [
              {
                # Before 2.42.0 mergerfs resolved entitlements from the host group
                # database instead of the process, so supplemental capability
                # groups did not authorize writes.
                assertion = lib.versionAtLeast pkgs.mergerfs.version "2.42.0";
                message = "services.mergerfs: mergerfs ${pkgs.mergerfs.version} cannot authorize supplemental storage groups; 2.42.0 or later is required";
              }
              {
                assertion = nonCanonicalPoolPaths == [ ];
                message = "services.mergerfs: pool paths must be canonical absolute paths: ${lib.concatStringsSep ", " nonCanonicalPoolPaths}";
              }
              {
                assertion = duplicatePaths == [ ];
                message = "services.mergerfs: backing paths may belong to only one pool: ${lib.concatStringsSep ", " duplicatePaths}";
              }
              {
                assertion = requiredWithoutUnit == [ ];
                message = "services.mergerfs: required backing paths need a mount unit: ${lib.concatStringsSep ", " requiredWithoutUnit}";
              }
              {
                assertion = optionalCreatePaths == [ ];
                message = "services.mergerfs: optional backing paths must be no-create: ${lib.concatStringsSep ", " optionalCreatePaths}";
              }
            ];
          }

          {
            systemd.services = lib.mapAttrs' (
              path: poolCfg:
              let
                escapedPath = lib.strings.sanitizeDerivationName (builtins.substring 1 (-1) path);
                units = builtins.filter (unit: unit != null) (map (branch: branch.unit) poolCfg.branches);
                requiredUnits = builtins.filter (unit: unit != null) (
                  map (branch: if branch.required then branch.unit else null) poolCfg.branches
                );
                optionalUnits = builtins.filter (unit: unit != null) (
                  map (branch: if branch.required then null else branch.unit) poolCfg.branches
                );
                options = lib.concatStringsSep "," poolCfg.options;
                mountScript = pkgs.writeShellScript "mount-mergerfs-${escapedPath}" ''
                  set -eu
                  if ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg path}; then
                    echo "mergerfs: ${path} is already mounted outside this unit" >&2
                    exit 1
                  fi
                  ${pkgs.coreutils}/bin/install -d -o root -g root -m 0000 ${lib.escapeShellArg path}
                  branches=
                  creatable=0
                  ${lib.concatMapStrings (
                    branch:
                    let
                      rendered = "${branch.path}=${if branch.create then "RW" else "NC"}";
                    in
                    ''
                      if ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg branch.path}; then
                        branch=${lib.escapeShellArg rendered}
                        branches="$branches''${branches:+:}$branch"
                        ${lib.optionalString branch.create "creatable=$((creatable + 1))"}
                      ${lib.optionalString branch.required ''
                        else
                          echo "mergerfs: required branch ${branch.path} is not mounted" >&2
                          exit 1
                      ''}
                      fi
                    ''
                  ) poolCfg.branches}
                  if [ "$creatable" -eq 0 ]; then
                    echo "mergerfs: no mounted creation-eligible branch remains for ${path}" >&2
                    exit 1
                  fi
                  exec ${pkgs.util-linux}/bin/mount -t fuse.mergerfs \
                    -o ${lib.escapeShellArg options} "$branches" ${lib.escapeShellArg path}
                '';
              in
              lib.nameValuePair (mergerfs.serviceNameFor path) {
                description = "MergerFS pool at ${path}";
                wantedBy = [ "multi-user.target" ] ++ requiredUnits;
                after = units ++ [ "local-fs.target" ];
                requires = requiredUnits;
                bindsTo = requiredUnits;
                partOf = requiredUnits;
                wants = optionalUnits;
                restartTriggers = [ mountScript ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = mountScript;
                  ExecStop = "${pkgs.fuse3}/bin/fusermount3 -uz ${lib.escapeShellArg path}";
                };
              }
            ) cfg;
          }

        ]
      );
  };
}
