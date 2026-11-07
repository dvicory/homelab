{
  inputs,
  self,
  lib,
  ...
}:
let
  nixosConfigs = lib.filterAttrs (_: cfg: cfg.config.deployment.enable or false) self.nixosConfigurations;

  toDeployNodes = lib.mapAttrs (name: _: let
    cfg = self.nixosConfigurations.${name}.config.deployment;
    system = self.nixosConfigurations.${name}.pkgs.stdenv.hostPlatform.system;
    knownHostsPath =
      if cfg.knownHostsPath != null then cfg.knownHostsPath else "/etc/ssh/ssh_known_hosts";

    # Use the pinned input on both sides of the activation protocol.
    deployPkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [ inputs.deploy-rs.overlays.default ];
    };
  in {
    hostname = if cfg.target != null then cfg.target else name;

    profiles.system = {
      sshUser = cfg.sshUser or "root";
      user = "root";

      sshOpts = [
        "-o"
        "StrictHostKeyChecking=yes"
        "-o"
        "UserKnownHostsFile=${knownHostsPath}"
        "-o"
        "Port=${toString (cfg.sshPort or 22)}"
      ];

      remoteBuild = true;
      interactiveSudo = true;

      path = deployPkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.${name};
    };
  }) nixosConfigs;
in
{
  flake-file.inputs = {
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
  };

  perSystem =
    { inputs', system, ... }:
    let
      nodes = lib.filterAttrs (
        name: _: self.nixosConfigurations.${name}.pkgs.stdenv.hostPlatform.system == system
      ) toDeployNodes;
    in
    {
      checks = lib.optionalAttrs (nodes != { }) (
        inputs.deploy-rs.lib.${system}.deployChecks (self.deploy // { inherit nodes; })
      );
      apps = {
        inherit (inputs'.deploy-rs.apps) deploy-rs;
      };
    };

  flake.deploy.nodes = toDeployNodes;
}
