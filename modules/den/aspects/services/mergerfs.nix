{ lib, ... }: {
  den.aspects.services.mergerfs = {
    settings.pools = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
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
      });
      default = { };
      description = "MergerFS pool definitions";
    };

    nixos = { host, config, pkgs, lib, ... }: let
      cfg = host.settings.services.mergerfs.pools or { };
      escapeSystemdPath = path:
        lib.strings.sanitizeDerivationName (builtins.substring 1 (-1) path);
    in lib.mkIf (cfg != { }) (lib.mkMerge [
      {
        environment.systemPackages = [ pkgs.mergerfs pkgs.attr ];
        boot.supportedFilesystems = [ "fuse" "fuse.mergerfs" ];
      }

      {
        environment.etc = lib.mapAttrs' (path: poolCfg:
          let
            escapedPath = escapeSystemdPath path;
            branchString = lib.concatStringsSep ":" poolCfg.branches;
            optionsString = lib.concatStringsSep "," (poolCfg.options or [ "allow_other" ]);
          in lib.nameValuePair "mergerfs/${escapedPath}.conf" {
            text = ''
              PATH=${path}
              BRANCHES=${branchString}
              OPTIONS=${optionsString}
            '';
          }
        ) cfg;
      }

      {
        systemd.services = lib.mapAttrs' (path: poolCfg:
          let
            escapedPath = escapeSystemdPath path;
          in lib.nameValuePair "mergerfs-mnt-${escapedPath}" {
            description = "MergerFS pool at ${path}";
            wantedBy = [ "multi-user.target" ];
            after = (poolCfg.depends or [ ]) ++ [ "local-fs.target" ];
            requires = poolCfg.depends or [ ];

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

      {
        systemd.paths = lib.mapAttrs' (path: poolCfg:
          let
            escapedPath = escapeSystemdPath path;
          in lib.nameValuePair "mergerfs-branch-${escapedPath}" {
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

      {
        systemd.services = lib.mapAttrs' (path: poolCfg:
          let
            escapedPath = escapeSystemdPath path;
          in lib.nameValuePair "mergerfs-branch-reload-${escapedPath}" {
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
            ${reloadCommands}
            echo "=== End MergerFS Activation Script ==="
          '' else ""
        );
      }

      {
        systemd.tmpfiles.rules = lib.mapAttrsToList (path: poolCfg:
          "d ${path} 0755 root root -"
        ) cfg;
      }

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
