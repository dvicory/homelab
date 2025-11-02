{ lib, ... }:
{
  flake.modules.generic.nix-common =
    { pkgs, ... }:
    {
      nix = {
        optimise = {
          automatic = lib.mkDefault true;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          dates = [ "05:00" ];
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          interval = [ { Hour = 18; } ];
        };

        gc.automatic = lib.mkDefault true;
        gc.options = lib.mkDefault "--delete-older-than 14d";
      };
    };
}
