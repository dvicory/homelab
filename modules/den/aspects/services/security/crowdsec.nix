{ inputs, ... }: {
  flake-file.inputs = {
    # CrowdSec refactor from TornaxO7's follow-up PR:
    # https://github.com/NixOS/nixpkgs/pull/535319
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
                config.config_paths.data_dir = persistDataDir;
                config.api.server.online_client.credentials_path =
                  "${persistDataDir}/online_api_credentials.yaml";

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

            # Keep CrowdSec data on the persistent dataset without relying on
            # systemd's private state-directory namespace.
            systemd.services.crowdsec-setup = {
              serviceConfig = {
                ExecStartPre = [
                  "+${pkgs.coreutils}/bin/mkdir -p ${persistDataDir}"
                  "+${pkgs.coreutils}/bin/chown -R crowdsec:crowdsec ${persistDataDir}"
                  "+${pkgs.coreutils}/bin/chmod -R 0750 ${persistDataDir}"
                  "+${pkgs.coreutils}/bin/chown -R crowdsec:crowdsec /etc/crowdsec"
                  "+${pkgs.coreutils}/bin/chmod 750 -R /etc/crowdsec"
                ];
              };
            };


            # Run cscli in the same sandboxed context as CrowdSec while
            # pointing it at the persistent data directory.
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
                      --working-directory=${persistDataDir}/hub \
                      --property=ExecPaths="${config.services.crowdsec.settings.config.config_paths.plugin_dir}" \
                      --property=User=${config.services.crowdsec.user} \
                      --property=Group=${config.services.crowdsec.group} \
                      --property=DynamicUser=true \
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
          systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.ReadWritePaths = lib.mkForce [
            persistDataDir
            "/var/lib/crowdsec-firewall-bouncer-register"
          ];
        };
      };
    };
  };
}
