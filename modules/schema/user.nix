{ lib, ... }: {
  den.schema.user = { lib, ... }: {
    config.classes = lib.mkDefault [ "homeManager" ];

    options = {
      sshKeys = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = "Paths to SSH public key files";
      };
      extraGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra groups for the user";
      };
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "User-specific packages";
      };

      mainGroup = lib.mkOption {
        type = lib.types.str;
        default = "staff";
        description = "Primary group for the user.";
      };
    };
  };
}
