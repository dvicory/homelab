{ lib, ... }: {
  den.schema.user = { lib, ... }: {
    config.classes = lib.mkDefault [ "homeManager" ];

    options = {
      sshKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "SSH public keys. Each entry is either an inline key string or a path to a `.pub` file (absolute or path literal).";
        apply = entries: lib.flatten (map (entry:
          if builtins.isPath entry then
            lib.splitString "\n" (lib.strings.trim (builtins.readFile entry))
          else if lib.strings.hasPrefix "/" entry && builtins.pathExists entry then
            lib.splitString "\n" (lib.strings.trim (builtins.readFile entry))
          else
            [ entry ]
        ) entries);
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
