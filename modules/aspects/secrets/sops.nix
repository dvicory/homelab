{ lib, inputs, den, ... }: {
  den.default.nixos =
    { config, lib, ... }:
    let
      inherit (lib) mkOption types;

      mkSopsSecret = name: req: {
        key = if req.key != null then req.key else "${config.networking.hostName}/${name}";
        mode = req.mode or "0400";
        owner = req.owner or "root";
        group = req.group or "root";
        restartUnits = req.restartUnits or [ ];
      } // lib.optionalAttrs (req.sopsFile != null) {
        sopsFile = req.sopsFile;
      } // lib.optionalAttrs req.neededForUsers {
        neededForUsers = true;
      };
    in
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];

      options.secretRequests = mkOption {
        type = types.attrsOf (types.submodule ({ name, ... }: {
          options = {
            provider = mkOption {
              type = types.enum [ "sops" "hardcoded" ];
              default = "sops";
              description = "Secret provider to fulfill this request.";
            };
            sopsFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "SOPS file this secret is encrypted in (defaults to host's sopsFile via sops.defaultSopsFile).";
            };
            key = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Key within the SOPS file (defaults to hostname/category/name).";
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
              description = "Systemd units to restart when the secret changes.";
            };
            neededForUsers = mkOption {
              type = types.bool;
              default = false;
              description = "Decrypt this secret before user activation (required for hashedPassword).";
            };
            content = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Inline secret content (hardcoded provider only). NOT SECURE for production.";
            };
            source = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Path to a file containing the secret (hardcoded provider only).";
            };
          };
        }));
        default = { };
        description = ''
          Provider-agnostic secret requests. Services declare what secrets they
          need, and provider aspects (sops, hardcoded) fulfill them.
        '';
      };

      config = {
        sops.defaultSopsFile = ./. + "/../../hosts/${config.networking.hostName}/secrets.yaml";
        sops.secrets = builtins.mapAttrs mkSopsSecret (
          lib.filterAttrs (_: req: req.provider or "sops" == "sops") config.secretRequests
        );
      };
    };
}
