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
      checks = (self.checks or { }).${system} or { };
    in
    assert lib.assertMsg (lib.all lib.isDerivation (
      lib.attrValues checks
    )) "CI checks.${system} must contain only derivations";
    checks;
  requiredFastChecks = [
    "den-semantics"
    "compute-contracts"
    "placement-contracts"
    "storage-roots-contracts"
    "mergerfs-contracts"
    "identity-contracts"
    "public-edge-contracts"
    "idmap-fixtures"
    "pod-security-contracts"
    "ssa-defaults-contracts"
    "jellyfin-contracts"
    "media-contracts"
    "media-storage-contracts"
    "seerr-credential-boundary"
    "alnum-no-newline"
    "generator-failure-closed"
    "compute-runtime"
    "household-bootstrap-generated"
    "prod-home-manifests-fresh"
    "prod-home-manifests-schema"
    "prod-home-manifests-policy"
    "argocd-application-health"
  ];
  # Runtime-Secret API, Argo and Gateway controller coverage runs natively
  # through the separately required verify-kubernetes-api app below.
  requiredKubernetesApplications = [
    "public-edge-runtime"
    "media-ingress-runtime"
  ];
  requiredHostRecovery = [
    "agenix-restart-guard"
    "classify-legacy-media"
    "prepare-luks-storage-runtime"
    "mergerfs-capability"
    "runtime-secret-k3s"
    "compute-ingress-runtime"
    "compute-network-policy-runtime"
    "compute-guest-upgrade"
    "identity-provision-runtime"
    "incus-mount-isolation"
    "root-esp-mirror"
    "prod-home-replacement"
  ];
  requiredFeaturesFor =
    check:
    check.requiredSystemFeatures or (check.config.rawTestDerivation.requiredSystemFeatures or [ ]);
  needsVm =
    check:
    lib.elem "kvm" (requiredFeaturesFor check)
    || lib.isDerivation (check.driver or (check.driverInteractive or (check.config.driver or null)));
  requiredNativeApplications = [
    "verify-kubernetes-api"
    "media-live-acceptance"
  ];
  nativeApplicationsFor =
    system:
    if system != "x86_64-linux" then
      { }
    else
      let
        packages = (self.packages or { }).${system} or { };
        apps = (self.apps or { }).${system} or { };
        valid =
          name:
          builtins.hasAttr name packages
          && lib.isDerivation packages.${name}
          && builtins.hasAttr name apps
          && (apps.${name}.type or "") == "app"
          && (apps.${name}.program or "") == lib.getExe packages.${name};
      in
      assert lib.assertMsg (lib.all valid requiredNativeApplications)
        "Required native CI apps must have matching executable packages: ${lib.concatStringsSep ", " requiredNativeApplications}";
      lib.genAttrs requiredNativeApplications (name: packages.${name});
  hostedChecksFor =
    system:
    let
      checks = checksFor system;
      fastRequired =
        requiredFastChecks
        ++ lib.optionals (lib.hasSuffix "-linux" system) [
          "prepare-luks-storage"
          "incus-mount-isolation-decisions"
        ];
      required =
        fastRequired
        ++ lib.optionals (system == "x86_64-linux") (
          requiredKubernetesApplications ++ requiredHostRecovery
        );
      missing = lib.filter (name: !(builtins.hasAttr name checks)) required;
      select = names: lib.genAttrs names (name: checks.${name});
    in
    assert lib.assertMsg (
      missing == [ ]
    ) "Missing required CI checks for ${system}: ${lib.concatStringsSep ", " missing}";
    assert lib.assertMsg (lib.all (
      name: lib.isDerivation checks.${name}
    ) required) "Required CI checks for ${system} must be derivations";
    assert lib.assertMsg (lib.all (
      name: !(needsVm checks.${name})
    ) fastRequired) "Required fast CI checks for ${system} must not require a VM";
    assert lib.assertMsg (
      system != "x86_64-linux"
      || lib.all (name: needsVm checks.${name}) (requiredKubernetesApplications ++ requiredHostRecovery)
    ) "Required hosted runtime checks must retain their VM boundary";
    assert builtins.isAttrs (nativeApplicationsFor system);
    {
      fastChecks = select fastRequired // lib.filterAttrs (_: check: !(needsVm check)) checks;
    }
    // lib.optionalAttrs (system == "x86_64-linux") {
      kubernetesApplications = select requiredKubernetesApplications;
      hostRecovery =
        select requiredHostRecovery
        // lib.filterAttrs (
          name: check: needsVm check && !(lib.elem name requiredKubernetesApplications)
        ) checks;
    };

  hostedInventoryFor =
    system:
    let
      groups = hostedChecksFor system;
      inventory = lib.mapAttrsToList (
        name: check:
        let
          matching = lib.filter (group: builtins.hasAttr name groups.${group}) (builtins.attrNames groups);
          hosted = !needsVm check || system == "x86_64-linux";
        in
        assert lib.assertMsg (
          builtins.length matching == (if hosted then 1 else 0)
        ) "Hosted CI must account for ${system}.${name} exactly once";
        {
          inherit name hosted;
          drvPath = if hosted then check.drvPath else null;
          runtime = needsVm check;
          requiredSystemFeatures = requiredFeaturesFor check;
          group = if hosted then lib.head matching else null;
          reason = if hosted then "" else "hosted runner has no KVM";
        }
      ) (checksFor system);
      nativeApplications = lib.mapAttrsToList (name: package: {
        inherit name;
        inherit (package) drvPath;
        program = lib.getExe package;
        group = "kubernetesApplications";
      }) (nativeApplicationsFor system);
    in
    {
      checks = inventory;
      inherit nativeApplications;
      jobGroups = builtins.attrNames groups ++ [
        "packages"
        "devShells"
        "formatters"
        "nixosConfigurations"
        "darwinConfigurations"
        "homeConfigurations"
      ];
    };

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
    hostedCiInventory = lib.genAttrs ciSystems hostedInventoryFor;
    ciBundles = lib.mapAttrs (
      system: jobs: withSystem system ({ pkgs, ... }: pkgs.linkFarm "ci-${system}" jobs)
    ) ciJobs;
    hostedCiJobs = lib.genAttrs ciSystems (
      system:
      withSystem system (
        { pkgs, ... }:
        lib.mapAttrs (name: entries: pkgs.linkFarm "ci-${name}-hosted" (project system "checks" entries)) (
          hostedChecksFor system
          // lib.optionalAttrs (system == "x86_64-linux") {
            kubernetesApplications =
              (hostedChecksFor system).kubernetesApplications // nativeApplicationsFor system;
          }
        )
      )
    );
  };
}
