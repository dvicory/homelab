{ inputs, ... }:
{
  # expose flake-parts options for nixd and nix repl
  debug = true;

  imports = [
    inputs.flake-file.flakeModules.default
    inputs.flake-parts.flakeModules.modules
  ];

  flake-file.description = "Homelab3 - Dendritic Architecture";

  flake-file.inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";
    flake-file.url = "github:vic/flake-file";
  };

  # flake-file.outputs = ''
  #   inputs:
  #   let
  #     base = inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
  #   in
  #     base // {
  #       # Example: add/override top-level outputs here
  #       # systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  #       # imports = [ ... ];
  #       # skarabox = {
  #       #   hosts = base.config.skarabox.hosts;
  #       # };
  #       # You can add more custom outputs as needed
  #     }
  # '';

  flake-file.outputs = ''
    inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; }
    (inputs.import-tree ./modules)
  '';

  # flake-file.outputs = ''
  #   inputs:
  #   let
  #     flake = inputs.flake-parts.lib.mkFlake { inherit inputs; }
  #       (inputs.import-tree ./modules);
  #   in
  #   flake // {
  #     # 👇 Make all flake.modules.* accessible as self.modules.*
  #     modules = flake.modules;
  #   }
  # '';
}
