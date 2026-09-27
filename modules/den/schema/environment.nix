{
  lib,
  den,
  ...
}:
let
  inherit (lib) mkOption types;
in
{
  config = {
    # Environments group independently managed machines and provide shared
    # context only where a policy or aspect consumes it explicitly.
    den.schema.environment.isEntity = true;

    den.schema.environment.imports = [
      (
        { config, ... }:
        {
          options = {
            domain = mkOption {
              type = types.str;
              description = "Shared base DNS namespace for this environment";
            };

            backupDomain = mkOption {
              type = types.str;
              default = "backup.${config.domain}";
              description = "Recovery DNS namespace for this environment";
            };

            timezone = mkOption {
              type = types.str;
              default = "UTC";
              description = "Shared timezone for hosts in this environment";
            };

            system-access-groups = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Group capabilities that permit Unix account presence on every host in this environment";
            };
          };
        }
      )
    ];
  };
}
