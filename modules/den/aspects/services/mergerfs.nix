{ lib, ... }:
let
  mergerfs = import ./_mergerfs.nix { inherit lib; };

  branchType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.addCheck lib.types.str mergerfs.isCanonicalPath;
        description = "Backing path: a mount point, or a directory below `mountPoint`.";
      };
      mountPoint = lib.mkOption {
        type = lib.types.nullOr (lib.types.addCheck lib.types.str mergerfs.isCanonicalPath);
        default = null;
        description = ''
          Mount that holds `path`, when only a subtree of it joins the pool
          (a disk's `pool/` directory). The branch is available only when this
          is mounted and `path` is a real directory on that same filesystem;
          the pool never creates `path`. Defaults to `path`.
        '';
      };
      unit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Systemd unit that mounts the backing path.";
      };
      fileSystemMount = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Depend on the mount unit systemd generates for the NixOS
          `fileSystems` entry at `mountPoint` (or `path`). The unit name is
          derived with `utils.escapeSystemdPath`; do not also set `unit`.
        '';
      };
      required = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether an unavailable backing path refuses the pool. Independent of
          `create`: a branch whose existing content the pool needs can be
          required and still receive no new content.
        '';
      };
      create = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether mergerfs may place new content on this backing path. Branches
          with `create = false` stay readable and modifiable, and their space is
          left out of the capacity the pool reports.
        '';
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
              # pfrd chooses among creation-eligible branches by free space and
              # does not require the parent path to exist there, so a new file
              # under a directory held only by a no-create branch still lands on
              # an eligible one. statfs=base with statfs-ignore=nc reports the
              # capacity of creation-eligible branches only. posix_acl lets the
              # kernel apply the branches' POSIX ACLs, including the default
              # ACLs that keep shared media group-writable.
              default = [
                "allow_other"
                "category.create=pfrd"
                "moveonenospc=false"
                "posix_acl=true"
                "statfs-ignore=nc"
                "statfs=base"
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
        config,
        pkgs,
        lib,
        utils,
        ...
      }:
      let
        cfg = host.settings.services.mergerfs.pools or { };
        mountOf = branch: if branch.mountPoint == null then branch.path else branch.mountPoint;
        # The unit a branch depends on: the declared unit, or the mount unit
        # systemd generates from the branch's fileSystems entry.
        branchUnit =
          branch:
          if branch.fileSystemMount then "${utils.escapeSystemdPath (mountOf branch)}.mount" else branch.unit;
        allBranches = lib.concatMap (pool: pool.branches) (builtins.attrValues cfg);
        unitAndFileSystemMount = map (branch: branch.path) (
          builtins.filter (branch: branch.fileSystemMount && branch.unit != null) allBranches
        );
        fileSystemMountWithoutEntry = map (branch: branch.path) (
          builtins.filter (
            branch: branch.fileSystemMount && !(config.fileSystems ? ${mountOf branch})
          ) allBranches
        );
        pathOutsideMount = map (branch: branch.path) (
          builtins.filter (
            branch: branch.mountPoint != null && !(lib.hasPrefix "${branch.mountPoint}/" branch.path)
          ) allBranches
        );
        nonCanonicalPoolPaths = mergerfs.nonCanonicalPoolPaths cfg;
        duplicateServiceNames = mergerfs.duplicateServiceNames cfg;
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
                assertion = duplicateServiceNames == [ ];
                message = "services.mergerfs: pool paths must map to distinct service names: ${lib.concatStringsSep ", " duplicateServiceNames}";
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
                assertion = unitAndFileSystemMount == [ ];
                message = "services.mergerfs: set either unit or fileSystemMount, not both: ${lib.concatStringsSep ", " unitAndFileSystemMount}";
              }
              {
                assertion = fileSystemMountWithoutEntry == [ ];
                message = "services.mergerfs: fileSystemMount branches need a fileSystems entry at their mount point: ${lib.concatStringsSep ", " fileSystemMountWithoutEntry}";
              }
              {
                assertion = pathOutsideMount == [ ];
                message = "services.mergerfs: a branch path must lie below its mountPoint: ${lib.concatStringsSep ", " pathOutsideMount}";
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
                units = builtins.filter (unit: unit != null) (map branchUnit poolCfg.branches);
                requiredUnits = builtins.filter (unit: unit != null) (
                  map (branch: if branch.required then branchUnit branch else null) poolCfg.branches
                );
                optionalUnits = builtins.filter (unit: unit != null) (
                  map (branch: if branch.required then null else branchUnit branch) poolCfg.branches
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
                  # A subtree branch counts only as a real directory on its mount,
                  # never as a same-named directory left on the root filesystem.
                  subtree_on_mount() {
                    [ -d "$1" ] && [ ! -L "$1" ] &&
                      [ "$(${pkgs.coreutils}/bin/stat -c %d -- "$1")" = "$(${pkgs.coreutils}/bin/stat -c %d -- "$2")" ]
                  }
                  ${lib.concatMapStrings (
                    branch:
                    let
                      rendered = "${branch.path}=${if branch.create then "RW" else "NC"}";
                      available =
                        "${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg (mountOf branch)}"
                        + lib.optionalString (branch.mountPoint != null)
                          " && subtree_on_mount ${lib.escapeShellArg branch.path} ${lib.escapeShellArg branch.mountPoint}";
                    in
                    ''
                      if ${available}; then
                        branch=${lib.escapeShellArg rendered}
                        branches="$branches''${branches:+:}$branch"
                        ${lib.optionalString branch.create "creatable=$((creatable + 1))"}
                      ${lib.optionalString branch.required ''
                        else
                          echo "mergerfs: required branch ${branch.path} is not available" >&2
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
