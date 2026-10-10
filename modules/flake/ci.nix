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
  requiredFastChecks = [
    "den-semantics"
    "compute-contracts"
    "placement-contracts"
    "storage-roots-contracts"
    "mergerfs-contracts"
    "identity-contracts"
    "public-edge-contracts"
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
    "media-runtime"
  ];
  requiredHostRecovery = [
    "agenix-restart-guard"
    "classify-legacy-media"
    "mergerfs-capability"
    "runtime-secret-k3s"
    "compute-ingress-runtime"
    "prod-home-replacement"
  ];
  # Native NixOS tests expose .driver; requiredSystemFeatures also catches
  # other checks that actually require KVM, regardless of Hestia display groups.
  needsVm = check: check ? driver || lib.elem "kvm" (check.requiredSystemFeatures or [ ]);
  hostedChecksFor =
    system:
    let
      checks = checksFor system;
      fastRequired = requiredFastChecks ++ lib.optional (lib.hasSuffix "-linux" system) "prepare-luks-storage";
      required = fastRequired ++ lib.optionals (system == "x86_64-linux") (
        requiredKubernetesApplications ++ requiredHostRecovery
      );
      missing = lib.filter (name: !(builtins.hasAttr name checks)) required;
      select = names: lib.genAttrs names (name: checks.${name});
    in
    assert lib.assertMsg (missing == [ ])
      "Missing required CI checks for ${system}: ${lib.concatStringsSep ", " missing}";
    assert lib.assertMsg (lib.all (name: lib.isDerivation checks.${name}) required)
      "Required CI checks for ${system} must be derivations";
    assert lib.assertMsg (lib.all (name: !(needsVm checks.${name})) fastRequired)
      "Required fast CI checks for ${system} must not require a VM";
    {
      fastChecks = select fastRequired // lib.filterAttrs (_: check: !(needsVm check)) checks;
    }
    // lib.optionalAttrs (system == "x86_64-linux") {
      kubernetesApplications = select requiredKubernetesApplications;
      hostRecovery = select requiredHostRecovery // lib.filterAttrs (
        name: check: needsVm check && !(lib.elem name requiredKubernetesApplications)
      ) checks;
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
              assert lib.assertMsg (self.apps.${system} ? verify-kubernetes-api)
                "Missing required CI app: verify-kubernetes-api";
              (hostedChecksFor system).kubernetesApplications
              // { verify-kubernetes-api = self.packages.${system}.verify-kubernetes-api; };
          }
        )
      )
    );
  };
}
