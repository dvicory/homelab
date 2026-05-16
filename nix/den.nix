{ lib, config, inputs, den, ... }:
let
  allHosts = lib.flatten (lib.mapAttrsToList (_: lib.attrValues) config.den.hosts);

  nixosHosts = builtins.filter (host: lib.hasSuffix "-linux" host.system) allHosts;
  darwinHosts = builtins.filter (host: lib.hasSuffix "-darwin" host.system) allHosts;

  build = builder: items:
    lib.listToAttrs (builtins.map (item: { name = item.name; value = builder item; }) items);

  mkNixos = host:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        host.mainModule
        { nixpkgs.hostPlatform = lib.mkDefault host.system; }
      ];
      specialArgs = {
        inherit inputs;
        self = inputs.self;
      };
    };

  mkDarwin = host:
    inputs.nix-darwin.lib.darwinSystem {
      modules = [
        host.mainModule
        { nixpkgs.hostPlatform = lib.mkDefault host.system; }
      ];
      specialArgs = { inherit inputs; };
    };
in
{
  # Den's auto-output modules disabled: we build outputs manually via the
  # build helpers above. This also avoids conflicts with clan output generation
  # when adopting clan later.
  disabledModules = [
    "${inputs.den}/modules/config.nix"
    "${inputs.den}/modules/outputs.nix"
  ];

  imports = [
    inputs.den.flakeModule
  ];

  _module.args.__findFile = den.lib.__findFile;

  flake = {
    nixosConfigurations = build mkNixos nixosHosts;
    darwinConfigurations = build mkDarwin darwinHosts;
  };
}
