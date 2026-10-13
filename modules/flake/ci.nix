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
  checksFor =
    system:
    let
      checks = self.checks.${system};
    in
    assert lib.assertMsg (lib.all lib.isDerivation (lib.attrValues checks))
      "CI checks.${system} must contain only derivations";
    checks;

  requiredFeaturesFor =
    check:
    # NixOS tests expose a lazy derivation; its raw derivation owns the features.
    check.requiredSystemFeatures or (check.config.rawTestDerivation.requiredSystemFeatures or [ ]);

  isRuntime =
    check:
    lib.elem "kvm" (requiredFeaturesFor check)
    || lib.isDerivation (
      check.driver or (check.driverInteractive or (check.config.driver or null))
    );

  checkInventory =
    system:
    let
      checks = checksFor system;
      inventory = lib.mapAttrsToList (name: check: {
        inherit name;
        inherit (check) drvPath;
        runtime = isRuntime check;
        requiredSystemFeatures = requiredFeaturesFor check;
        hosted = !isRuntime check || system == "x86_64-linux";
        reason = if isRuntime check && system != "x86_64-linux" then "hosted runner has no KVM" else "";
      }) checks;
      fast = builtins.filter (entry: !entry.runtime) inventory;
      runtime = builtins.filter (entry: entry.runtime && entry.hosted) inventory;
      unsupported = builtins.filter (entry: !entry.hosted) inventory;
    in
    assert lib.assertMsg (
      builtins.length (fast ++ runtime ++ unsupported) == builtins.length inventory
      && lib.sort builtins.lessThan (map (entry: entry.name) (fast ++ runtime ++ unsupported))
      == builtins.attrNames checks
    ) "Hosted CI must partition every checks.${system} registration exactly once";
    {
      inherit inventory fast runtime unsupported;
    };

  hostedChecksFor =
    system: lib.filterAttrs (_: check: !isRuntime check) (checksFor system);

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
    hostedCiInventory = lib.genAttrs ciSystems checkInventory;
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
