/**
  # Secret Contract (Dendritic hybrid)

  Contract definition is here, providers are in contracts/secret/providers/*.nix

  This is the main aspect file that gets imported, but providers are
  automatically discovered via import-tree.
*/
{ lib, ... }:
let
  inherit (lib) mkOption;

  # The contract is a function that takes lib from the consumer
  mkSecretContract = consumerLib: {
    # Creates a request option for services that need secrets
    mkRequest =
      args:
      mkOption {
        description = "Secret requirements (mode, owner, group, restart behavior)";
        type = consumerLib.types.submodule {
          options = {
            mode = mkOption {
              type = consumerLib.types.str;
              default = args.mode or "0400";
              description = "File permissions for the secret (e.g., '0400', '0440')";
            };

            owner = mkOption {
              type = consumerLib.types.str;
              default = args.owner or "root";
              description = "User that should own the secret file";
            };

            group = mkOption {
              type = consumerLib.types.str;
              default = args.group or "root";
              description = "Group that should own the secret file";
            };

            restartUnits = mkOption {
              type = consumerLib.types.listOf consumerLib.types.str;
              default = args.restartUnits or [ ];
              description = "Systemd units to restart when the secret changes";
            };
          };
        };
        default = {
          mode = args.mode or "0400";
          owner = args.owner or "root";
          group = args.group or "root";
          restartUnits = args.restartUnits or [ ];
        };
      };

    # Creates a result option for providers that deliver secrets
    mkResult =
      args:
      mkOption {
        description = "Secret location provided by the secret provider";
        type = consumerLib.types.submodule {
          options = {
            path = mkOption {
              type = consumerLib.types.path;
              default = args.path or "/run/secrets/secret";
              description = ''
                Absolute path to the secret file on the deployed system.
                This path is not available in the Nix store.
              '';
            };
          };
        };
      };
  };
in
{
  # Export to flake.contracts
  config.flake.contracts.secret = mkSecretContract;
}
