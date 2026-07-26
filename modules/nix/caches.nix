let
  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
    ];

    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };
in
{
  flake-file = { inherit nixConfig; };

  flake.modules.generic.nix-common = {
    nix = {
      settings = nixConfig;
    };
  };
}
