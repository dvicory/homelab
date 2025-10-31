{
  inputs,
  self,
  lib,
  ...
}:
let
  # TODO: only supports nixos right now, so we filter to nixos hosts that have a configuration
  nixosHosts = lib.filterAttrs (name: _: lib.hasAttr name self.nixosConfigurations) self.dlab.hosts;

  toDeployNodes =
    hosts: nixosConfigurations:
    lib.mapAttrs (
      name: host:
      let
        deployPkgs =
          let
            pkgs' = import inputs.nixpkgs {
              inherit (host) system;
            };
          in
          import inputs.nixpkgs {
            inherit (host) system;
            overlays = [
              inputs.deploy-rs.overlays.default
              (self: super: {
                deploy-rs = {
                  inherit (pkgs') deploy-rs;
                  lib = super.deploy-rs.lib;
                };
              })
            ];
          };

        deploy = host.deploy or { };
        hostname = deploy.target or name;
        user = "root";
        sshUser = deploy.user or "root";
      in
      {
        inherit hostname;
        profiles.system = {
          sshUser = sshUser;
          user = user;
          sshOpts = [
            "-o"
            "StrictHostKeyChecking=yes"
            "-o"
            "UserKnownHostsFile=${deploy.knownHostsPath}"
            "-o"
            "Port=${toString (deploy.sshPort or 22)}"
          ];
          # autoRollback = false;
          # magicRollback = false;
          remoteBuild = true;

          path = deployPkgs.deploy-rs.lib.activate.nixos nixosConfigurations.${name};
        };
      }
    ) hosts;
in
{
  flake-file.inputs = {
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
  };

  perSystem =
    { inputs', ... }:
    {
      apps = {
        inherit (inputs'.deploy-rs.apps) deploy-rs;
      };
    };

  flake.deploy.nodes = toDeployNodes nixosHosts self.nixosConfigurations;
}
