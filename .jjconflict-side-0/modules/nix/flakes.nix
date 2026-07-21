let
  nixConfig = {
    experimental-features = [
      "nix-command"
      "flakes"
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
