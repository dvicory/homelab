{ lib, ... }:
{
  flake.modules.generic.nix-common =
    { config, ... }:
    let
      allowed = config.nix.allowedUnfree;
    in
    {
      options.nix = {
        allowedUnfree = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Allows for unfree packages by name.
          '';
        };
      };

      config = lib.mkIf (allowed != [ ]) {
        nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) allowed;
      };
    };
}
