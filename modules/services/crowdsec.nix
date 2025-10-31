/**
  # CrowdSec Service

  CrowdSec is an open-source, collaborative intrusion prevention system.

  ## Features
  - Detects and blocks malicious IPs
  - Community-driven threat intelligence
  - Firewall bouncer for automatic IP blocking

  ## Configuration
  - Local API mode (no cloud enrollment required)
  - Firewall bouncer configured automatically
  - Auto-registers bouncer with API key
  - Monitors SSH logs via journald
  - Auto-installs collections: crowdsecurity/linux, crowdsecurity/sshd

  ## Implementation Details

  ### Using Kampka's Modules

  This module uses **Kampka's NixOS modules** (not nixpkgs) because:

  1. **enrollKeyFile support**: Kampka's crowdsec module provides `services.crowdsec.enrollKeyFile` option for cloud enrollment
  2. **firewall-bouncer module**: nixpkgs doesn't have a module for the firewall bouncer at all
  3. **disabledModules**: Required because both nixpkgs and Kampka declare `services.crowdsec`

  **Package versions:**
  - CrowdSec engine: 1.6.10 (from Kampka's flake - required for module compatibility)
  - Firewall bouncer: 0.0.34 (from nixpkgs - Kampka's module defaults to `pkgs` version)

  **Why not use nixpkgs modules?**
  - Kampka's crowdsec module expects `package.patterns` attribute which nixpkgs doesn't provide
  - nixpkgs doesn't have a firewall-bouncer module
  - We need `enrollKeyFile` option for cloud integration

  **Extension:**
  - Adds secret contract options on top for SOPS integration

  ## Persistence

  CrowdSec needs the following directories persisted:
  - `/var/lib/crowdsec` - Database, decisions, local API state

  ## Resources
  - Upstream: https://codeberg.org/solitango/nix-flake-crowdsec
  - Docs: https://docs.crowdsec.net/
*/
{ inputs, ... }:
{
  flake-file.inputs = {
    crowdsec = {
      url = "git+https://codeberg.org/solitango/nix-flake-crowdsec";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  flake.modules.nixos.services-crowdsec =
    {
      config,
      lib,
      options,
      pkgs,
      ...
    }:
    let
      cfg = config.services.crowdsec;
      hostName = config.dlab.hostName;
      bouncerCfg = config.services.crowdsec-firewall-bouncer;
      contracts = config._contracts;
    in
    {
      # Use Kampka's modules instead of nixpkgs
      #
      # Why disabledModules is required:
      # - Both nixpkgs and Kampka declare services.crowdsec.enable (conflict)
      # - Kampka's module expects package.patterns attribute (incompatible with nixpkgs package)
      # - Need enrollKeyFile option which nixpkgs doesn't provide
      # - Need firewall-bouncer module which nixpkgs doesn't have
      disabledModules = [
        "services/security/crowdsec.nix"
      ];

      imports = [
        inputs.crowdsec.nixosModules.crowdsec
        inputs.crowdsec.nixosModules.crowdsec-firewall-bouncer
      ];

      # Define secret requirements using the secret contract
      # Extend the CrowdSec engine options
      options.services.crowdsec = {
        secrets = lib.mkOption {
          description = "Secret contracts for CrowdSec engine";
          type = lib.types.submodule {
            options = {
              bouncerApiKeyFile = lib.mkOption {
                description = ''
                  Secret contract for the bouncer API key.

                  This key is used for local communication between the CrowdSec engine
                  and the firewall bouncer. The engine uses it to register bouncers.

                  Required when CrowdSec is enabled.
                '';
                type = lib.types.submodule {
                  options = contracts.secret.mkRequester {
                    owner = "crowdsec";
                    mode = "0660";
                    restartUnits = [
                      "crowdsec.service"
                      "crowdsec-firewall-bouncer.service"
                    ];
                  };
                };
              };

              enrollKeyFile = lib.mkOption {
                description = ''
                  Secret contract for CrowdSec cloud enrollment.

                  This key connects your instance to the CrowdSec community
                  for threat intelligence sharing.

                  Required when CrowdSec is enabled.
                '';
                type = lib.types.submodule {
                  options = contracts.secret.mkRequester {
                    owner = "crowdsec";
                    mode = "0660";
                    restartUnits = [ "crowdsec.service" ];
                  };
                };
              };
            };
          };
        };
      };

      # Extend the firewall bouncer options
      options.services.crowdsec-firewall-bouncer = {
        secrets = lib.mkOption {
          description = "Secret contracts for CrowdSec firewall bouncer";
          type = lib.types.submodule {
            options = {
              apiKeyFile = lib.mkOption {
                description = ''
                  Secret contract for the bouncer's API key.

                  This key authenticates the bouncer with the CrowdSec engine.
                  Typically shares the same secret as services.crowdsec.secrets.bouncerApiKeyFile.

                  Required when the firewall bouncer is enabled.
                '';
                type = lib.types.submodule {
                  options = contracts.secret.mkRequester {
                    owner = "root";
                    mode = "0400";
                    restartUnits = [ "crowdsec-firewall-bouncer.service" ];
                  };
                };
              };
            };
          };
        };
      };

      config = lib.mkMerge [
        # CrowdSec engine configuration
        (lib.mkIf cfg.enable {
          # Note: Must use Kampka's package (not nixpkgs) because Kampka's module
          # expects package.patterns attribute which nixpkgs doesn't provide
          # (nixpkgs: 1.7.0, Kampka: 1.6.10)

          # Allow CrowdSec to read journald for SSH logs
          services.crowdsec.allowLocalJournalAccess = true;

          # Local API configuration and acquisitions
          services.crowdsec.settings =
            let
              yaml = (pkgs.formats.yaml { }).generate;
              # Monitor SSH authentication logs via journald
              sshAcquisition = yaml "ssh-acquisition.yaml" {
                source = "journalctl";
                journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
                labels.type = "syslog";
              };
            in
            {
              # TODO: this should be configurable?
              api.server = {
                listen_uri = "127.0.0.1:8080";
              };

              # Point to our acquisitions file
              crowdsec_service.acquisition_path = sshAcquisition;
            };

          # Connect to CrowdSec cloud for threat intelligence
          services.crowdsec.enrollKeyFile = cfg.secrets.enrollKeyFile.result.path;

          # TODO: upstream to set Type=Notify for proper systemd integration?
          # without this, systemd starts crowdsec-firewall-bouncer before crowdsec is ready
          systemd.services.crowdsec.serviceConfig.Type = "notify";

          # Setup CrowdSec collections and bouncer registration
          systemd.services.crowdsec.serviceConfig.ExecStartPre = lib.mkAfter (
            let
              # Install collections for parsing SSH logs
              setupCollectionsScript = pkgs.writeScriptBin "setup-crowdsec-collections" ''
                #!${pkgs.runtimeShell}
                set -eu
                set -o pipefail

                echo "Installing CrowdSec collections..."

                # Install base collections
                # These are idempotent - won't reinstall if already present
                cscli collections install crowdsecurity/linux || true

                echo "CrowdSec collections installed"

                cscli capi status
              '';

              # Register firewall bouncer if enabled
              registerBouncerScript = lib.optionalString bouncerCfg.enable (
                let
                  bouncerKeyFile = cfg.secrets.bouncerApiKeyFile.result.path;
                  bouncerName = "${hostName}-firewall-bouncer";
                in
                pkgs.writeScriptBin "register-bouncer" ''
                  #!${pkgs.runtimeShell}
                  set -eu
                  set -o pipefail

                  BOUNCER_KEY=$(cat ${bouncerKeyFile})

                  # TODO: use JSON to parse output
                  if ! cscli bouncers list | grep -q "${bouncerName}"; then
                    echo "Registering firewall bouncer..."
                    cscli bouncers add "${bouncerName}" --key "$BOUNCER_KEY"
                  fi
                ''
              );
            in
            [ "${setupCollectionsScript}/bin/setup-crowdsec-collections" ]
            ++ lib.optional bouncerCfg.enable "${registerBouncerScript}/bin/register-bouncer"
          );
        })

        # Firewall bouncer configuration
        (lib.mkIf bouncerCfg.enable {
          # Note: Kampka's module defaults to pkgs.crowdsec-firewall-bouncer (0.0.34 from nixpkgs)
          # This is newer than Kampka's own package (0.0.31)

          services.crowdsec-firewall-bouncer.settings = {
            # Non-sensitive settings only - api_key will be injected at runtime
            api_url = "http://localhost:8080";
          };

          # Create runtime config with secret injected
          systemd.services.crowdsec-firewall-bouncer =
            let
              format = pkgs.formats.yaml { };
              # Base config without secrets
              baseConfig = format.generate "crowdsec-base.yaml" bouncerCfg.settings;
              runtimeConfigPath = "/run/crowdsec-firewall-bouncer/config.yaml";
              setupApiKey = pkgs.writeScriptBin "setup-firewall-bouncer-api-key" ''
                #!${pkgs.runtimeShell}
                set -eu
                set -o pipefail

                # Create runtime directory
                mkdir -p /run/crowdsec-firewall-bouncer

                # Read API key and merge with base config
                API_KEY=$(cat ${bouncerCfg.secrets.apiKeyFile.result.path})

                # Combine base config with secret
                {
                  echo "api_key: $API_KEY"
                  cat ${baseConfig}
                } > ${runtimeConfigPath}
              '';
            in
            {
              serviceConfig.ExecStart = lib.mkForce "${config.services.crowdsec-firewall-bouncer.package}/bin/cs-firewall-bouncer -c ${runtimeConfigPath}";
              serviceConfig.ExecStartPre = lib.mkForce [
                "${setupApiKey}/bin/setup-firewall-bouncer-api-key"
                "${config.services.crowdsec-firewall-bouncer.package}/bin/cs-firewall-bouncer -t -c ${runtimeConfigPath}"
              ];
            };
        })

        (lib.mkIf (cfg.enable) {
          # Database, decisions, local API state persistence
          dlab.impermanence.additionalDirectories = [
            {
              directory = "/var/lib/crowdsec";
              user = "crowdsec";
              group = "crowdsec";
            }
          ];
        })
      ];
    };
}
