{ lib, ... }:
{
  options.flake.lib.dlab = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "DLab library functions available throughout the flake.";
  };
}
