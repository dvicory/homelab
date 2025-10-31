{
  self,
  inputs,
  config,
  lib,
  ...
}:
{
  options = {
    pkgs-overlays = lib.mkOption {
      type = with lib.types; listOf raw;
      default = [ ];
      description = ''
        List of overlays to apply to nixpkgs.
        These will be applied in perSystem for build-time pkgs.
      '';
    };

    pkgs-config = lib.mkOption {
      type = with lib.types; attrsOf raw;
      default = { };
      description = ''
        Additional nixpkgs config options.
        Example: { allowUnfree = true; }
      '';
    };
  };

  # config = {
  #   perSystem = { system, ... }: {
  #     _module.args.pkgs = import inputs.nixpkgs {
  #       inherit system;
  #       config = {
  #         allowUnfree = true;
  #       } // config.pkgs-config;
  #       overlays = [
  #         # Self packages as overlay
  #         (_final: _prev: self.packages.${system} or {})
  #       ] ++ config.pkgs-overlays;
  #     };
  #   };
  # };

  # config.perSystem =
  #   { system, ... }:
  #   {
  #     _module.args.pkgs = import inputs.nixpkgs {
  #       inherit system;
  #       config = {
  #         allowUnfree = true;
  #       }
  #       // config.pkgs-config;
  #       overlays = [
  #         (_final: _prev: self.packages.${system})
  #       ]
  #       ++ config.pkgs-overlays;
  #     };
  #   };
}
