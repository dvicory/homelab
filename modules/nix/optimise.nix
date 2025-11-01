{ lib, ... }:
{
  flake.modules.generic.nix-common = {
    nix = {
      optimise.automatic = lib.mkDefault true;
      optimise.dates = lib.mkDefault [ "05:00" ];

      gc.automatic = lib.mkDefault true;
      gc.options = lib.mkDefault "--delete-older-than 14d";
    };
  };
}
