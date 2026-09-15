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
  checksFor = system: (self.checks or { }).${system} or { };
  hostedChecksFor =
    system:
    lib.filterAttrs (_: check: !(lib.hasSuffix "runtime" (check.meta.hestia.group or ""))) (
      checksFor system
    );

  ciJobs = lib.genAttrs ciSystems (
    system:
    withSystem system (
      { pkgs, ... }:
      lib.mapAttrs (name: entries: pkgs.linkFarm "ci-${name}" entries) {
        packages = project system "packages" ((self.packages or { }).${system} or { });
        checks = project system "checks" (checksFor system);
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
      }
    )
  );
in
{
  flake = {
    # Pick up standard flake outputs without duplicating their inventory in CI.
    inherit ciJobs;
    ciBundles = lib.mapAttrs (
      system: jobs: withSystem system ({ pkgs, ... }: pkgs.linkFarm "ci-${system}" jobs)
    ) ciJobs;
    hostedCiJobs = lib.genAttrs ciSystems (
      system:
      withSystem system (
        { pkgs, ... }:
        {
          checks = pkgs.linkFarm "ci-checks-hosted" (project system "checks" (hostedChecksFor system));
        }
      )
    );
  };
}
