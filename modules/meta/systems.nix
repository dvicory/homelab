{ inputs, ... }:
{
  flake-file.inputs = {
    systems.url = "github:nix-systems/triplet";
  };

  systems = import inputs.systems;
}
