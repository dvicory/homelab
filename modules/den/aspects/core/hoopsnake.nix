{ inputs, ... }:
{
  den.aspects.core.hoopsnake.nixos =
    { ... }:
    {
      imports = [ inputs.hoopsnake.nixosModules.default ];
    };
}
