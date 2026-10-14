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
    # Read the lazy test's feature declarations without forcing its raw derivation.
    if check ? config.requiredFeatures then
      builtins.attrNames (lib.filterAttrs (_: enabled: enabled) check.config.requiredFeatures)
    else
      check.requiredSystemFeatures or [ ];

  isRuntime =
    check:
    lib.elem "kvm" (requiredFeaturesFor check)
    || lib.elem "uid-range" (requiredFeaturesFor check)
    || lib.isDerivation (
      check.driver or (check.driverInteractive or (check.config.driver or null))
    );

  checkInventory =
    system:
    let
      checks = checksFor system;
      inventory = lib.mapAttrsToList (
        name: check:
        let
          requiredSystemFeatures = requiredFeaturesFor check;
          linux = lib.hasSuffix "-linux" system;
          requirements = {
            kvm = lib.elem "kvm" requiredSystemFeatures;
            uidRange = lib.elem "uid-range" requiredSystemFeatures;
            cgroups = lib.elem "uid-range" requiredSystemFeatures;
          };
          supportedFeatures = [
            "benchmark"
            "big-parallel"
            "nixos-test"
          ] ++ lib.optional (system == "x86_64-linux") "kvm"
            ++ lib.optional linux "uid-range";
          unsupportedFeatures = lib.subtractLists supportedFeatures requiredSystemFeatures;
          hosted = unsupportedFeatures == [ ];
        in
        {
          inherit name requiredSystemFeatures requirements hosted;
          # Unsupported Linux tests on Darwin must remain inspectable, not evaluated.
          drvPath = if hosted then check.drvPath else null;
          runtime = isRuntime check;
          reason = lib.concatMapStringsSep "; " (
            feature:
            if feature == "kvm" then
              "hosted runner has no KVM"
            else if feature == "uid-range" then
              "hosted runner cannot run Linux UID-range containers"
            else
              "hosted runner lacks required system feature ${feature}"
          ) unsupportedFeatures;
        }
      ) checks;
      fast = builtins.filter (entry: !entry.runtime && entry.hosted) inventory;
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
    system:
    let
      names = map (entry: entry.name) (checkInventory system).fast;
    in
    lib.filterAttrs (name: _: lib.elem name names) (checksFor system);

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
