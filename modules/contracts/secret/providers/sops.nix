# SOPS secret provider (Dendritic hybrid)
# Provides flake.modules.nixos.secret-sops-provider
{ inputs, ... }:
{
  flake-file.inputs = {
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules.nixos.secret-sops-provider =
    { config, lib, ... }:
    let
      inherit (lib) mapAttrs mkOption;
      inherit (lib.types) attrsOf anything submodule;
      contracts = config._contracts;
      cfg = config.dlab.sops;
    in
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];
      options.dlab.sops = {
        secret = mkOption {
          description = ''
            Secret following the secret contract.
            This is a SOPS provider that fulfills secret requests
            using sops-nix as the underlying implementation.
          '';
          default = { };
          type = attrsOf (
            submodule (
              { name, ... }:
              {
                options = contracts.secret.mkProvider {
                  settings = mkOption {
                    description = ''
                      Settings specific to the SOPS provider.
                      This is a passthrough option to set sops-nix options.
                      Note that `mode`, `owner`, `group`, and `restartUnits`
                      are managed by the request option.
                    '';
                    type = attrsOf anything;
                    default = { };
                  };
                  resultCfg = {
                    path = "/run/secrets/${name}";
                    pathText = "/run/secrets/<name>";
                  };
                };
              }
            )
          );
        };
      };
      config = {
        sops.secrets =
          let
            mkSecret = n: secretCfg: secretCfg.request // secretCfg.settings;
          in
          mapAttrs mkSecret cfg.secret;
      };
    };
}
