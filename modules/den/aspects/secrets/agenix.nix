{ lib, inputs, ... }: {
  den.default.nixos =
    { config, lib, ... }:
    let
      inherit (lib) filterAttrs mapAttrs mapAttrs' nameValuePair mkOption types;

      mkAgeSecret = name: req:
        {
          rekeyFile = req.ageFile;
          mode = req.mode or "0400";
          owner = req.owner or "root";
          group = req.group or "root";
        };

      agenixReqs = filterAttrs (
        _: req: req.provider or "agenix" == "agenix" && req.ageFile or null != null
      ) config.secretRequests;

      restartReqs = filterAttrs (
        _: req: (req.restartUnits or [ ]) != [ ]
      ) agenixReqs;
    in
    {
      options.secretRequests = mkOption {
        type = types.attrsOf (types.submodule ({ name, ... }: {
          options = {
            provider = mkOption {
              type = types.enum [ "agenix" ];
              default = "agenix";
              description = "Secret provider to fulfill this request.";
            };
            ageFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Path to the age-encrypted secret file.";
            };
            mode = mkOption {
              type = types.str;
              default = "0400";
              description = "File permissions for the decrypted secret.";
            };
            owner = mkOption {
              type = types.str;
              default = "root";
              description = "User who should own the secret file.";
            };
            group = mkOption {
              type = types.str;
              default = "root";
              description = "Group who should own the secret file.";
            };
            restartUnits = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Systemd units to restart when the secret file changes.";
            };
          };
        }));
        default = { };
        description = ''
          Provider-agnostic secret requests. Services declare what secrets they
          need, and the agenix provider fulfills them.
        '';
      };

      config = {
        age.secrets = mapAttrs mkAgeSecret agenixReqs;

        systemd.paths = mapAttrs' (name: _:
          nameValuePair "agenix-restart-${name}" {
            wantedBy = [ "multi-user.target" ];
            pathConfig.PathModified = config.age.secrets.${name}.path;
          }
        ) restartReqs;

        systemd.services = mapAttrs' (name: req:
          nameValuePair "agenix-restart-${name}" {
            serviceConfig.Type = "oneshot";
            serviceConfig.ExecStart = "${config.systemd.package}/bin/systemctl try-restart ${lib.concatStringsSep " " req.restartUnits}";
          }
        ) restartReqs;
      };
    };

  den.aspects.secrets.agenix = {
    persist = {
      # Agenix-rekey generators state
    };
  };
}
