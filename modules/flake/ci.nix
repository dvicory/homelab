{
  self,
  withSystem,
  lib,
  ...
}:
let
  ciSystems = [
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-darwin"
  ];

  grouped =
    system: group: drv:
    drv
    // {
      meta = (drv.meta or { }) // {
        hestia = (drv.meta.hestia or { }) // {
          group = drv.meta.hestia.group or "${system}-${group}";
        };
      };
    };

  project =
    system: group: attrs:
    lib.filterAttrs (_: value: value != null) (
      lib.mapAttrs (
        _: value:
        if lib.isDerivation value then
          grouped system group value
        else if builtins.isAttrs value then
          let
            nested = project system group value;
          in
          if nested == { } then null else nested
        else
          null
      ) attrs
    );

  configurationsFor =
    system: output: build:
    lib.mapAttrs (_: configuration: grouped system output (build configuration)) (
      lib.filterAttrs (_: configuration: configuration.pkgs.stdenv.hostPlatform.system == system) (
        self.${output} or { }
      )
    );

  collectDerivations =
    value:
    if lib.isDerivation value then
      [ value ]
    else if builtins.isAttrs value then
      lib.concatMap collectDerivations (builtins.attrValues value)
    else
      [ ];

  ciJobs = lib.genAttrs ciSystems (system: {
    packages = project system "packages" ((self.packages or { }).${system} or { });
    checks = project system "checks" ((self.checks or { }).${system} or { });
    devShells = project system "development" ((self.devShells or { }).${system} or { });
    formatters = project system "development" {
      default = (self.formatter or { }).${system} or null;
    };
    nixosConfigurations = configurationsFor system "nixosConfigurations" (
      configuration: configuration.config.system.build.toplevel
    );
    darwinConfigurations = configurationsFor system "darwinConfigurations" (
      configuration: configuration.system
    );
    homeConfigurations = configurationsFor system "homeConfigurations" (
      configuration: configuration.activationPackage
    );
  });
in
{
  flake = {
    # Hestia evaluates this projection once. New standard flake outputs are
    # picked up here without duplicating their inventory in GitHub Actions.
    inherit ciJobs;

    # One symlink-only root per system lets the protected publication job push
    # the complete successful projection, including jobs Hestia already cached.
    ciBundles = lib.mapAttrs (
      system: jobs:
      withSystem system (
        { pkgs, ... }:
        pkgs.linkFarm "homelab-ci-${system}" (
          lib.imap0 (index: drv: {
            name = toString index;
            path = drv;
          }) (collectDerivations jobs)
        )
      )
    ) ciJobs;
  };
}
