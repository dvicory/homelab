/**
  # Contracts Infrastructure

  This module provides the contracts infrastructure following the SelfHostBlocks pattern.

  Files in this directory:
  - `default.nix` (this file) - Declares flake.contracts option & exports mkContractFunctions helper
  - `secret.nix` - Secret contract definition
  - `<future>.nix` - Additional contract definitions

  ## What it provides:

  1. **`flake.contracts.*`** - Exportable contract definitions for external flakes
     - `flake.contracts.mkContractFunctions` - Helper to wrap contracts
     - `flake.contracts.secret` - Secret contract definition (from secret.nix)

  2. **`config._contracts.*`** - Pre-instantiated contracts for internal use
     - `config._contracts.secret` - Ready-to-use secret contract with mkRequester/mkProvider

  ## Usage (External Flakes):
  ```nix
  inputs.homelab.contracts.mkContractFunctions
    (inputs.homelab.contracts.secret { inherit lib; })
  ```

  ## Usage (Internal):
  ```nix
  { config, ... }:
  {
    options.myService.secretFile = lib.types.submodule {
      options = config._contracts.secret.mkRequester {
        owner = "myservice";
        mode = "0400";
      };
    };
  }
  ```
*/
{ config, lib, ... }:
let
  inherit (lib) mkOption optionalAttrs;
  inherit (lib.types) anything;

  # SelfHostBlocks-style contract infrastructure
  # Creates mkRequester and mkProvider functions for each contract
  mkContractFunctions =
    {
      mkRequest,
      mkResult,
    }:
    {
      # For services that NEED something (consumers)
      mkRequester = requestCfg: {
        request = mkRequest requestCfg;
        result = mkResult { };
      };

      # For blocks that PROVIDE something (providers)
      mkProvider =
        {
          resultCfg,
          settings ? { },
        }:
        {
          request = mkRequest { };
          result = mkResult resultCfg;
        }
        // optionalAttrs (settings != { }) { inherit settings; };

      # Contract definition (for documentation/reference)
      contract = {
        request = mkRequest { };
        result = mkResult { };
        settings = mkOption {
          description = ''
            Optional attribute set with options specific to the provider.
          '';
          type = anything;
        };
      };
    };

in
{
  # Declare flake.contracts option with freeform type for multi-file contribution
  # (secret.nix will contribute to this)
  options.flake.contracts = lib.mkOption {
    type = lib.types.submoduleWith {
      modules = [
        {
          freeformType = lib.types.lazyAttrsOf lib.types.raw;
        }
      ];
    };
    default = { };
    description = ''
      Contract library functions for the homelab flake.

      Contracts decouple service requirements from infrastructure providers.
      Each contract provides mkRequest and mkResult functions.
    '';
  };

  # Export mkContractFunctions helper for external use
  config.flake.contracts.mkContractFunctions = mkContractFunctions;

  # Export a NixOS module that provides _contracts to all NixOS configurations
  config.flake.modules.nixos.contracts-provider =
    { config, lib, ... }:
    {
      options._contracts = mkOption {
        description = ''
          Internal contracts infrastructure (pre-instantiated).

          This provides mkRequester and mkProvider functions for each contract,
          following the SelfHostBlocks pattern.

          Pattern:
          - Requesters declare what they need via .request
          - Providers fulfill needs and provide .result
          - End users wire request → provider and result → requester
        '';
        internal = true;
        type = lib.types.anything;
      };

      # Pre-instantiate contracts for NixOS modules
      # Note: We use the flake-level contract definitions
      config._contracts.secret = mkContractFunctions {
        mkRequest =
          args:
          mkOption {
            description = "Secret requirements (mode, owner, group, restart behavior)";
            type = lib.types.submodule {
              options = {
                mode = mkOption {
                  type = lib.types.str;
                  default = args.mode or "0400";
                  description = "File permissions for the secret (e.g., '0400', '0440')";
                };
                owner = mkOption {
                  type = lib.types.str;
                  default = args.owner or "root";
                  description = "User that should own the secret file";
                };
                group = mkOption {
                  type = lib.types.str;
                  default = args.group or "root";
                  description = "Group that should own the secret file";
                };
                restartUnits = mkOption {
                  type = lib.types.listOf lib.types.str;
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
        mkResult =
          args:
          mkOption {
            description = "Secret location provided by the secret provider";
            type = lib.types.submodule {
              options = {
                path = mkOption {
                  type = lib.types.path;
                  description = ''
                    Absolute path to the secret file on the deployed system.
                    This path is not available in the Nix store.
                  '';
                };
              };
            };
            default = {
              path = args.path or "/run/secrets/secret";
            };
          };
      };
    };
}
