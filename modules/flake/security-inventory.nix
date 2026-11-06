{ self, config, lib, ... }:
let
  # Reuse the CI platform inventory, but inventory deployment roots and released
  # packages rather than test/dev-shell closures. Compute guests are ordinary
  # nixosConfigurations and therefore need no second host list.
  systems = builtins.attrNames self.hostedCiPlan;
  # Standard package outputs are derivations by the flake contract. Inspecting
  # even their type/meta here can force foreign Helm IFD through policy exports.
  # Native jobs resolve one selected value only after executor placement.
  packageRows = system: attrs: map (name: {
    target = "packages.${system}.${name}";
    inherit system;
    kind = "nix";
    state = "desired";
    source = "modules/flake/packages.nix";
    update = "flake.lock and the package's source declaration; review local patches/vendor hashes";
  }) (builtins.attrNames attrs);
  hostNames = system: output:
    builtins.filter (name: builtins.hasAttr name ((config.den.hosts or {}).${system} or {}))
      (builtins.attrNames (self.${output} or {}));
  configRows = system: output: suffix: map (name: {
    kind = "nix";
    state = "desired";
    inherit system;
    target = "${output}.${name}.${suffix}";
    source = "modules/den";
    update = "root nixpkgs input and evaluated service/package overrides";
  }) (hostNames system output);
  hostImages = system:
    lib.concatLists (lib.mapAttrsToList (name: c:
      let
        cfg = c.config;
        containers = cfg.virtualisation.oci-containers.containers or {};
        quadlets = cfg.virtualisation.quadlet.containers or {};
        homes = cfg.home-manager.users or {};
        row = source: image: {
          kind = "oci";
          state = "desired";
          inherit system image source;
          update = "image declaration; application internals remain upstream-owned";
        };
      in lib.mapAttrsToList (container: v: row "nixosConfigurations.${name}.config.virtualisation.oci-containers.${container}" v.image) containers
        ++ lib.mapAttrsToList (container: v: row "nixosConfigurations.${name}.config.virtualisation.quadlet.${container}" v.containerConfig.image) quadlets
        ++ lib.concatLists (lib.mapAttrsToList (user: home:
          lib.mapAttrsToList (container: v: row "nixosConfigurations.${name}.config.home-manager.users.${user}.virtualisation.quadlet.${container}" v.containerConfig.image)
            (home.virtualisation.quadlet.containers or {})
        ) homes)
    ) (lib.genAttrs (hostNames system "nixosConfigurations") (name: self.nixosConfigurations.${name})));
in {
  flake.securityInventory = lib.genAttrs systems (system:
    let
      environments = (self.nixidyEnvs or {}).${system} or {};
      # These exports contain rendered manifests, not native runtime software;
      # their declared images are inventoried without forcing Helm IFD here.
      manifestPackages = map (name: "${name}-manifests") (builtins.attrNames environments);
    in {
    schema = 1;
    inherit system;
    nativeSupported = lib.hasSuffix "-linux" system;
    roots = configRows system "nixosConfigurations" "config.system.build.toplevel"
      ++ configRows system "darwinConfigurations" "system"
      ++ packageRows system (
        lib.removeAttrs ((self.packages or {}).${system} or {}) manifestPackages
      );
    images = hostImages system;
    manifests = lib.mapAttrsToList (name: _: {
      target = "nixidyEnvs.${system}.${name}.config.build.environmentPackage";
      packageTarget = "packages.${system}.${name}-manifests";
      platform = config.den.clusters.${name}.hostSystem or null;
      source = "generated/manifests/${name}";
      state = "desired";
    }) environments;
    limits = [
      "Desired evaluation is not deployment evidence. No production profiles or Kubernetes APIs are contacted."
      "Built output reference closures exclude build-only dependencies and do not prove code reachability."
      "Nix CPE/name/version matching is heuristic; local backports and identity collisions require review."
      "Reusable native SBOM rescans use Grype CPE matching; Nix-unsupported OSV, Vulnix and automatic patch suppression are not applied."
      "Trivy covers supported languages and OCI distributions, not native Nix package CVEs."
      "Dynamic downloaded images/binaries and application-owned internals absent from declarations are unsupported."
      "Immutable SHA input pins remain mapped but automatic HEAD replacement is disabled until the owner declares an authorized branch URL or supported release-tag policy."
    ];
  });
}
