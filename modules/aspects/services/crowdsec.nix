{ inputs, ... }: {
  den.aspects."dlab/services/crowdsec" = {
    nixos = { config, lib, pkgs, ... }: let
      cfg = config.services.crowdsec;
      hostName = config.networking.hostName;
    in {
      disabledModules = [
        "services/security/crowdsec.nix"
      ];

      imports = [
        inputs.crowdsec.nixosModules.crowdsec
      ];

      config = lib.mkMerge [
        {
          secretRequests."crowdsec/bouncerApiKey" = {
            mode = "0660";
            owner = "crowdsec";
            restartUnits = [
              "crowdsec.service"
              "crowdsec-firewall-bouncer.service"
            ];
          };

          secretRequests."crowdsec/enrollmentKey" = {
            mode = "0660";
            owner = "crowdsec";
            sopsFile = ../../../shared/secrets.yaml;
            key = "crowdsec/enrollment_key";
            restartUnits = [ "crowdsec.service" ];
          };
        }

        (lib.mkIf cfg.enable {
          services.crowdsec.allowLocalJournalAccess = true;

          services.crowdsec.settings =
            let
              yaml = (pkgs.formats.yaml { }).generate;
              sshAcquisition = yaml "ssh-acquisition.yaml" {
                source = "journalctl";
                journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
                labels.type = "syslog";
              };
            in
            {
              api.server.listen_uri = "127.0.0.1:8080";
              crowdsec_service.acquisition_path = sshAcquisition;
            };

          services.crowdsec.enrollKeyFile = config.sops.secrets."crowdsec/enrollmentKey".path;

          systemd.services.crowdsec.serviceConfig.Type = "notify";

          systemd.services.crowdsec.serviceConfig.ExecStartPre = lib.mkAfter (
            let
              setupCollectionsScript = pkgs.writeScriptBin "setup-crowdsec-collections" ''
                #!${pkgs.runtimeShell}
                set -eu
                set -o pipefail
                echo "Installing CrowdSec collections..."
                ${pkgs.crowdsec}/bin/cscli collections install crowdsecurity/linux || true
                echo "CrowdSec collections installed"
                ${pkgs.crowdsec}/bin/cscli capi status
              '';
            in
            [ "${setupCollectionsScript}/bin/setup-crowdsec-collections" ]
          );
        })
      ];
    };

    provides.bouncer = {
      nixos = { config, lib, pkgs, ... }: let
        bouncerCfg = config.services.crowdsec-firewall-bouncer;
        hostName = config.networking.hostName;
      in {
        disabledModules = [
          "services/security/crowdsec-firewall-bouncer.nix"
        ];

        imports = [
          inputs.crowdsec.nixosModules.crowdsec-firewall-bouncer
        ];

        config = lib.mkIf bouncerCfg.enable {
          services.crowdsec-firewall-bouncer.settings = {
            api_url = "http://localhost:8080";
          };

          systemd.services.crowdsec-firewall-bouncer =
            let
              format = pkgs.formats.yaml { };
              baseConfig = format.generate "crowdsec-base.yaml" bouncerCfg.settings;
              runtimeConfigPath = "/run/crowdsec-firewall-bouncer/config.yaml";
              setupApiKey = pkgs.writeScriptBin "setup-firewall-bouncer-api-key" ''
                #!${pkgs.runtimeShell}
                set -eu
                set -o pipefail
                mkdir -p /run/crowdsec-firewall-bouncer
                API_KEY=$(cat ${config.sops.secrets."crowdsec/bouncerApiKey".path})
                {
                  echo "api_key: $API_KEY"
                  cat ${baseConfig}
                } > ${runtimeConfigPath}
              '';

              registerBouncerScript = pkgs.writeScriptBin "register-bouncer" ''
                #!${pkgs.runtimeShell}
                set -eu
                set -o pipefail
                BOUNCER_KEY=$(cat ${config.sops.secrets."crowdsec/bouncerApiKey".path})
                if ! ${pkgs.crowdsec}/bin/cscli bouncers list | grep -q "${hostName}-firewall-bouncer"; then
                  echo "Registering firewall bouncer..."
                  ${pkgs.crowdsec}/bin/cscli bouncers add "${hostName}-firewall-bouncer" --key "$BOUNCER_KEY"
                fi
              '';
            in
            {
              serviceConfig.ExecStart = lib.mkForce "${config.services.crowdsec-firewall-bouncer.package}/bin/cs-firewall-bouncer -c ${runtimeConfigPath}";
              serviceConfig.ExecStartPre = lib.mkForce [
                "${setupApiKey}/bin/setup-firewall-bouncer-api-key"
                "${config.services.crowdsec-firewall-bouncer.package}/bin/cs-firewall-bouncer -t -c ${runtimeConfigPath}"
                "${registerBouncerScript}/bin/register-bouncer"
              ];
            };
        };
      };
    };
  };
}
