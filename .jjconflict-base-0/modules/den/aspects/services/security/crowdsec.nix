{ inputs, ... }: {
  flake-file.inputs = {
    # CrowdSec PR refactor (based on TornaxO7's rewrite
    # https://github.com/NixOS/nixpkgs/pull/446307).
    # Reference config: https://github.com/1randomguy/nixconfig/blob/main/modules/nixos/homelab/services/crowdsec.nix
    crowdsec-pr.url = "github:dvicory/nixpkgs/crowdsec";
  };

  den.aspects.services.security.crowdsec = {
    nixos = { config, lib, pkgs, ... }:
      let
        cfg = config.services.crowdsec;
        persistDataDir = "/persist/crowdsec/data";
      in {
        disabledModules = [
          "services/security/crowdsec.nix"
        ];

        imports = [
          "${inputs.crowdsec-pr}/nixos/modules/services/security/crowdsec.nix"
        ];

        config = lib.mkMerge [
          {
            secretRequests."crowdsec-enrollmentKey" = {
              provider = "agenix";
              mode = "0400";
              owner = "root";
              ageFile = inputs.self + "/.secrets/hosts/${config.networking.hostName}/crowdsec-enrollmentKey.age";
              restartUnits = [ "crowdsec.service" ];
            };
          }

          (lib.mkIf cfg.enable {
            services.crowdsec = {
              autoUpdateService = true;

              package = pkgs.callPackage "${inputs.crowdsec-pr}/pkgs/by-name/cr/crowdsec/package.nix" { };

              hub.collections = [ "crowdsecurity/linux" ];

              settings = {
                config.api.server.online_client.credentials_path =
                  "/var/lib/crowdsec/data/online_api_credentials.yaml";

                acquisitions = [
                  {
                    labels.type = "syslog";
                    source = "journalctl";
                    journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
                  }
                ];

                console.enrollKeyFile = config.age.secrets."crowdsec-enrollmentKey".path;
              };
            };

            # DynamicUser + ZFS persist: ZFS doesn't support id-mapped
            # mounts required for DynamicUser's user namespace setup. If a
            # ZFS mount sits inside the StateDirectory path, systemd fails
            # at step NAMESPACE with EBUSY.
            #
            # openzfs/zfs#12923 — FS_ALLOW_IDMAP not yet implemented.
            #
            # Workaround: persist data outside the StateDirectory
            # (/persist/crowdsec/data) and symlink into it at runtime.
            # The id-mapped mount covers only the symlink inode (on
            # tmpfs/rootfs), not the ZFS data behind it. Ownership is
            # fixed each boot via chown resolved through nss-systemd
            # (dynamic users are visible to getpwnam).
            systemd.services.crowdsec-setup = {
              serviceConfig = {
                ExecStartPre = [
                  "+${pkgs.coreutils}/bin/mkdir -p ${persistDataDir}"
                  "+${pkgs.coreutils}/bin/chown -R crowdsec:crowdsec ${persistDataDir}"
                  "+${pkgs.coreutils}/bin/chmod -R 0750 ${persistDataDir}"
                  "+${pkgs.coreutils}/bin/chown -R crowdsec:crowdsec /etc/crowdsec"
                  "+${pkgs.coreutils}/bin/chmod 750 -R /etc/crowdsec"
                  # Host-level symlink: survives oneshot namespace teardown.
                  # StateDirectory is created AFTER +ExecStartPre, so we
                  # mkdir the parent ourselves here.
                  "+${pkgs.coreutils}/bin/mkdir -p /var/lib/private/crowdsec"
                  "+${pkgs.coreutils}/bin/rm -rf /var/lib/private/crowdsec/data"
                  "+${pkgs.coreutils}/bin/ln -sfn ${persistDataDir} /var/lib/private/crowdsec/data"
                ];
                ReadWritePaths = [ persistDataDir ];
              };
            };

            systemd.services.crowdsec.serviceConfig.ReadWritePaths = [
              persistDataDir
            ];

            systemd.services.crowdsec-update-hub.serviceConfig.ReadWritePaths = [
              persistDataDir
            ];

            # PR module's cscli wrapper uses systemd-run for a transient
            # DynamicUser unit. It's missing ReadWritePaths so interactive
            # cscli commands fail to access the ZFS persist dir via the
            # symlink. Override with the same wrapper plus the property.
            environment.systemPackages = lib.mkBefore [
              (pkgs.symlinkJoin {
                name = "cscli";
                paths = [
                  (pkgs.writeShellScriptBin "cscli" ''
                    exec ${pkgs.systemd}/bin/systemd-run \
                      --quiet \
                      --pty \
                      --wait \
                      --collect \
                      --pipe \
                      --service-type=exec \
                      --working-directory=/var/lib/crowdsec/data/hub \
                      --property=ExecPaths="${config.services.crowdsec.settings.config.config_paths.plugin_dir}" \
                      --property=User=${config.services.crowdsec.user} \
                      --property=Group=${config.services.crowdsec.group} \
                      --property=DynamicUser=true \
                      --property=StateDirectory="crowdsec" \
                      --property=StateDirectoryMode="0750" \
                      --property=ConfigurationDirectory="crowdsec" \
                      --property=ConfigurationDirectoryMode="0750" \
                      --property=ReadWritePaths=${persistDataDir} \
                      --property=SupplementaryGroups=systemd-journal \
                      -- \
                      ${config.services.crowdsec.package}/bin/cscli "$@"
                  '')
                ];
              })
            ];
          })
        ];
      };

    provides.bouncer = {
      nixos = { config, lib, pkgs, ... }: let
        persistDataDir = "/persist/crowdsec/data";
      in {
        disabledModules = [
          "services/security/crowdsec-firewall-bouncer.nix"
        ];

        imports = [
          "${inputs.crowdsec-pr}/nixos/modules/services/security/crowdsec-firewall-bouncer.nix"
        ];

        config = lib.mkIf config.services.crowdsec-firewall-bouncer.enable {
          systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.ReadWritePaths = [
            persistDataDir
          ];
          systemd.services.crowdsec-firewall-bouncer.serviceConfig.ReadWritePaths = [
            persistDataDir
          ];
        };
      };
    };
  };
}
