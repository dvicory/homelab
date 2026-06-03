{
  lib,
  inputs,
  self,
  ...
}:
let
  inherit (lib) mkOption types;
  schemaLib = inputs.gen-schema.lib;
in
{
  den.schema.environment.isEntity = true;

  den.schema.environment.imports = [
    (
      { config, ... }:
      {
        options = {
          id = mkOption {
            type = types.int;
            default = 0;
            description = "Numeric ID of the environment";
          };

          secretPath = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to the directory containing secrets for this environment";
          };

          settings =
            mkOption {
              type = types.attrsOf (types.attrsOf types.anything);
              default = { };
              description = "Environment-level default feature settings for scope-engine cascade";
            }
            // {
              identity = false;
            };
        };

        config = {
          secretPath = lib.mkDefault (self + "/.secrets/env/${config.name}");
        };
      }
    )
  ];
}