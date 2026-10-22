{
  config,
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
    assert lib.assertMsg (lib.all lib.isDerivation (
      lib.attrValues checks
    )) "CI checks.${system} must contain only derivations";
    checks;

  # Mandatory identities are safety contracts, not executor-selection groups.
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
    "media-producer-exit"
    "seerr-credential-boundary"
    "alnum-no-newline"
    "generator-failure-closed"
    "compute-runtime"
    "household-bootstrap-generated"
    "prod-home-manifests-fresh"
    "prod-home-manifests-schema"
    "prod-home-manifests-policy"
    "argocd-application-health"
    "verification-reports"
  ];
  requiredKubernetesApplications = [
    "public-edge-runtime"
    "media-ingress-runtime"
    "household-directory-runtime"
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
    "prod-home-consumer-resilience"
  ];
  requiredNativeApplications = [
    "verify-kubernetes-api"
    "media-live-acceptance"
    "household-sign-in-runtime"
  ];

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
    || lib.isDerivation (check.driver or (check.driverInteractive or (check.config.driver or null)));

  checkInventory =
    system:
    let
      checks = checksFor system;
      fastRequired =
        requiredFastChecks
        ++ lib.optionals (lib.hasSuffix "-linux" system) [
          "prepare-luks-storage"
          "incus-mount-isolation-decisions"
        ]
        ++ lib.optional (system == "x86_64-linux") "prod-home-registry-failures";
      runtimeRequired =
        lib.optionals (system == "x86_64-linux") (requiredKubernetesApplications ++ requiredHostRecovery)
        ++ lib.optional (system == "aarch64-linux") "agenix-restart-guard";
      required = fastRequired ++ runtimeRequired;
      missing = lib.filter (name: !(builtins.hasAttr name checks)) required;
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
          ]
          ++ lib.optional (system == "x86_64-linux") "kvm"
          ++ lib.optional linux "uid-range";
          unsupportedFeatures = lib.subtractLists supportedFeatures requiredSystemFeatures;
          hosted = unsupportedFeatures == [ ];
        in
        {
          inherit
            name
            requiredSystemFeatures
            requirements
            hosted
            ;
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
      missing == [ ]
    ) "Missing required CI checks for ${system}: ${lib.concatStringsSep ", " missing}";
    assert lib.assertMsg (lib.all (
      name: !isRuntime checks.${name}
    ) fastRequired) "Required fast CI checks for ${system} must not require a runtime driver";
    assert lib.assertMsg (lib.all (
      name: isRuntime checks.${name}
    ) runtimeRequired) "Required hosted runtime checks must retain their runtime boundary";
    assert lib.assertMsg (lib.all (
      name: (lib.findFirst (entry: entry.name == name) null inventory).hosted
    ) required) "Required CI checks for ${system} must remain hosted on their required platform";
    assert builtins.isList (nativeApplicationsFor system);
    assert lib.assertMsg (
      builtins.length (fast ++ runtime ++ unsupported) == builtins.length inventory
      &&
        lib.sort builtins.lessThan (map (entry: entry.name) (fast ++ runtime ++ unsupported))
        == builtins.attrNames checks
    ) "Hosted CI must partition every checks.${system} registration exactly once";
    {
      inherit
        inventory
        fast
        runtime
        unsupported
        ;
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

  nativeApplicationsFor =
    system:
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
      descriptors = [
        {
          name = "media-live-acceptance";
          package = "packages.${system}.media-live-acceptance";
          arguments = [
            "--docker-host"
            "unix:///var/run/docker.sock"
            "--platform"
            "linux/amd64"
          ];
          timeoutSeconds = 2700;
          requirements.docker = true;
          cleanupPrefix = "homelab-media-live-";
        }
        {
          name = "household-sign-in-runtime";
          package = "packages.${system}.household-sign-in-runtime";
          arguments = [ ];
          timeoutSeconds = 3000;
          requirements = {
            docker = true;
            root = true;
            ownedStorage = true;
          };
          loopbackHost = builtins.head config.den.clusters."prod-home".routes.idm.hostnames;
          cleanupPrefix = "household";
        }
        {
          name = "verify-kubernetes-api";
          package = "packages.${system}.verify-kubernetes-api";
          arguments = [
            "--docker-context"
            "default"
            "--report"
            "kubernetes-api-result.json"
          ];
          reportFile = "kubernetes-api-result.json";
          reportCheckArguments = [
            "--check-report"
            "kubernetes-api-result.json"
          ];
          timeoutSeconds = 7200;
          requirements.docker = true;
          cleanupPrefix = "homelab-api-";
        }
      ];
    in
    if system != "x86_64-linux" then
      [ ]
    else
      assert lib.assertMsg (lib.all valid requiredNativeApplications)
        "Required native CI apps must have matching executable packages: ${lib.concatStringsSep ", " requiredNativeApplications}";
      assert lib.assertMsg (
        lib.sort builtins.lessThan (map (entry: entry.name) descriptors)
        == lib.sort builtins.lessThan requiredNativeApplications
      ) "Required native CI apps must be registered exactly once";
      descriptors;

  hostedPlanFor =
    system:
    let
      nativeApplications = nativeApplicationsFor system;
      names = builtins.attrNames (checksFor system) ++ map (app: app.name) nativeApplications;
    in
    assert lib.assertMsg (
      builtins.length names == builtins.length (lib.unique names)
    ) "Hosted CI checks and native applications must be uniquely registered on ${system}";
    {
      inventory = builtins.mapAttrs (_: map (entry: builtins.removeAttrs entry [ "drvPath" ])) (
        checkInventory system
      );
      groups = builtins.attrNames ciJobs.${system};
      inherit nativeApplications;
    };

  artifactFor = package: {
    inherit (package) drvPath;
    outputs = lib.genAttrs package.outputs (output: package.${output}.outPath);
  };

  # Select one leaf on its executor, after platform/bootstrap preparation.
  # In particular, never serialize foreign or unsupported derivations in the plan.
  hostedArtifactsFor =
    system:
    let
      inventory = checkInventory system;
    in
    {
      inherit inventory;
      groups = lib.mapAttrs (_: artifactFor) (ciJobs.${system} // self.hostedCiJobs.${system});
      checks = lib.listToAttrs (
        map (entry: lib.nameValuePair entry.name (artifactFor (checksFor system).${entry.name})) (
          inventory.fast ++ inventory.runtime
        )
      );
      nativeApplications = lib.listToAttrs (
        map (
          application:
          lib.nameValuePair application.name (
            artifactFor (lib.getAttrFromPath (lib.splitString "." application.package) self)
            // {
              program = self.apps.${system}.${application.name}.program;
            }
          )
        ) (nativeApplicationsFor system)
      );
      bootstrap = lib.optionalAttrs (system == "aarch64-linux") {
        darwinLinuxBuilder = artifactFor self.darwinConfigurations.daniels-2021-mbp.config.nix.linux-builder.package.nixosConfig.system.build.toplevel;
      };
    };
in
{
  flake = {
    # Pick up standard flake outputs without duplicating their inventory in CI.
    inherit ciJobs;
    hostedCiInventory = lib.genAttrs ciSystems checkInventory;
    hostedCiPlan = lib.genAttrs ciSystems hostedPlanFor;
    hostedCiArtifacts = lib.genAttrs ciSystems hostedArtifactsFor;
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
