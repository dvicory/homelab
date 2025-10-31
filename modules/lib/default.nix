{ lib, ... }:
{
  options.flake.lib = lib.mkOption {
    type = lib.types.submoduleWith {
      modules = [
        {
          freeformType = lib.types.lazyAttrsOf lib.types.raw;
        }
      ];
    };
    default = { };
    description = ''
      Utility functions exported to the flake.
      Available as `self.lib.*` in configurations.
    '';
  };
}
