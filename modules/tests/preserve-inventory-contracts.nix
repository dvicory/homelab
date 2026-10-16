{
  config,
  inputs,
  lib,
  self,
  ...
}:
let
  hvn = self.nixosConfigurations.hvn-hyp1.config;
  inventory = hvn.homelab.preserve.desiredInventory;
  states = builtins.listToAttrs (
    map (entry: {
      name = entry.stateId;
      value = entry;
    }) inventory.states
  );
  issuesOf = entry: entry.issues ++ lib.concatMap (route: route.issues) entry.routes;
  home = states."household/home";
  persist = states."household/persist";
  compute = config.den.hosts.x86_64-linux.hvn-hyp1.settings.virtualization.compute;
  resources = config.flake.clusterResources.prod-home;
  descriptor = builtins.fromJSON hvn.environment.etc."homelab/compute.json".text;
  profile = lib.findFirst (
    entry: entry.name == compute.profile && entry.project == compute.project
  ) null hvn.virtualisation.incus.preseed.profiles;
  idmap = (import ../den/aspects/virtualization/_idmap.nix { inherit lib; }).plan {
    inherit (compute) idmapBase idmapSize;
    inherit (descriptor) capabilityGids;
  };
  persistedDirectories = hvn.environment.persistence."/persist".directories;
  persistedStateRoot = lib.findFirst (
    entry: entry.directory == compute.stateRoot
  ) null persistedDirectories;
  retained = builtins.attrValues compute.retainedPaths;
  # Reuse real typed State/Route identities, with isolated owner wiring only.
  fenceOwners =
    (inputs.gen-schema.inputs.gen-merge.lib.evalModuleTree {
      modules = [
        {
          options.targets = inputs.gen-schema.lib.mkInstanceRegistry config.den.schema."preserve-target" {
            extraModules = [ { config._identity.keys = [ "targetId" ]; } ];
          };
          options.integrations =
            inputs.gen-schema.lib.mkInstanceRegistry config.den.schema."preserve-integration"
              {
                extraModules = [ { config._identity.keys = [ "integrationId" ]; } ];
              };
          config = {
            targets.retained = {
              targetId = "fixture-retained";
              failureDomain.domain = "fixture";
            };
            integrations.inspect = {
              integrationId = "fixture-inspect";
              owner = "fixture-owner";
              adapter = "/fixture/never-dispatched";
              fixtureOnly = true;
              operations = [
                "describe"
                "status"
                "points"
              ];
              dataKinds = [ "*" ];
              requiredSourceCapabilities = [ "filesystem-read" ];
              guaranteedConsistency = "filesystem";
              fidelityGuarantees = [ "posix-filesystem" ];
              nativePointRepresentations = [ "fixture-point/v1" ];
            };
          };
        }
      ];
    }).config;
  retainedBoundaries = {
    paths = [ "/fixture/retained" ];
    nativeLocators = [ "fixture/retained" ];
    nativeNamespace = "fixture-native";
  };
  fenceCompile =
    homeMode: persistMode: targetBoundaries: contributions:
    let
      route = config.den.preserve.routes.household-route // {
        target = fenceOwners.targets.retained;
        integration = fenceOwners.integrations.inspect;
        operation = "status";
      };
      fixtureStates = lib.mapAttrs (
        name: state:
        state
        // {
          mode = if name == "household/home" then homeMode else persistMode;
          explicitPolicy = state.explicitPolicy // {
            routes = [ route ];
          };
        }
      ) config.den.preserve.states;
    in
    config.fleet.preserve.compile {
      states = fixtureStates;
      routes.household-route = route;
      targets = fenceOwners.targets;
      integrations = fenceOwners.integrations;
      bindings = [ ];
      integrationTargets = [
        {
          inherit targetBoundaries;
          target = fenceOwners.targets.retained;
          integration = fenceOwners.integrations.inspect;
          native = { };
        }
      ];
      realizations = map (entry: {
        state = fixtureStates.${entry.stateId};
        inherit (entry) realization;
      }) contributions;
      projectors = { };
      scratchDestinations = { };
      fixtureOnly = true;
    };
  bothEnabled = fenceCompile "enabled" "enabled" retainedBoundaries inventory.states;
  retainedTransition = fenceCompile "enabled" "plan-only" retainedBoundaries inventory.states;
  missingRetained = fenceCompile "enabled" "plan-only" null inventory.states;
  emptyRetained = fenceCompile "enabled" "plan-only" {
    paths = [ ];
    nativeLocators = [ ];
  } inventory.states;
  missingSource = fenceCompile "plan-only" "plan-only" retainedBoundaries [ ];
  invalidRetained = fenceCompile "plan-only" "plan-only" {
    paths = [ "relative/retained" ];
  } inventory.states;
  throws = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  assertions = {
    household-states =
      builtins.attrNames states == [
        "household/home"
        "household/persist"
      ]
      && inventory.kind == "desired-inventory"
      && inventory.fixtureOnly == false;
    evaluated-dataset-bindings =
      home.realization.path == hvn.disko.devices.zpool.rpool.datasets."safe/home".mountpoint
      && home.realization.locator == "rpool/safe/home"
      && home.realization.owner.id == "hvn-hyp1"
      && persist.realization.path == hvn.disko.devices.zpool.rpool.datasets."safe/persist".mountpoint
      && persist.realization.locator == "rpool/safe/persist"
      && persist.realization.owner.id == "hvn-hyp1";
    distinct-slots = home.slotId == "household/home" && persist.slotId == "household/host-role-persist";
    # This is actual current host desired state, not the synthetic platform model.
    retained-host-boundary =
      compute.stateRoot == "/var/lib/homelab/compute-1/state"
      && compute.stateGuestPath == "/srv/state"
      && persistedStateRoot != null
      && persistedStateRoot.user == toString (idmap.hostUid 0)
      && persistedStateRoot.group == toString (idmap.hostGid 0)
      && persistedStateRoot.mode == "0755"
      && hvn.fileSystems."/persist".neededForBoot
      && builtins.elem ("d ${persist.realization.path}${compute.stateRoot} 0755 ${toString (idmap.hostUid 0)} ${toString (idmap.hostGid 0)} -") hvn.systemd.tmpfiles.rules
      && builtins.attrNames compute.retainedPaths == builtins.attrNames resources.retainedPaths
      && retained != [ ]
      && builtins.all (
        name:
        let
          entry = compute.retainedPaths.${name};
        in
        entry.path == "${compute.stateRoot}/${name}"
        && entry.guestPath == "${compute.stateGuestPath}/${name}"
        && entry.uid == resources.retainedPaths.${name}.uid
        && entry.gid == resources.retainedPaths.${name}.gid
        && entry.mode == resources.retainedPaths.${name}.mode
        && !entry.readOnly
        # Only the parent crosses Incus; no per-app source or duplicate persist bind.
        && !(builtins.any (device: (device.source or null) == entry.path) (
          builtins.attrValues profile.devices
        ))
        && !(builtins.any (directory: directory.directory == entry.path) persistedDirectories)
      ) (builtins.attrNames compute.retainedPaths);
    exact-incus-projection =
      descriptor.retainedPaths == compute.retainedPaths
      && descriptor.idmap.uid == idmap.uid
      && descriptor.idmap.gid == idmap.gid
      && profile.config."raw.idmap" == idmap.rawIdmap
      && profile.devices.state.source == compute.stateRoot
      && profile.devices.state.path == compute.stateGuestPath
      && profile.devices.state.required == "true"
      && profile.devices.state.readonly == "false"
      && profile.devices.state.propagation == "rprivate"
      && idmap.hostUid 0 == 1000000
      && idmap.hostUid 751 == 1000751
      && idmap.hostGid 751 == 1000751
      && idmap.hostGid config.den.groups.media.gid == config.den.groups.media.gid
      && idmap.hostUid config.den.groups.media.gid != config.den.groups.media.gid
      && compute.retainedPaths.jellyfin-config.uid == 751
      && compute.retainedPaths.jellyfin-config.gid == 751
      && compute.retainedPaths.identity-kanidm.uid == 1000
      && compute.retainedPaths.identity-kanidm.gid == 1000
      && compute.retainedPaths.kubernetes-volumes.uid == 0
      && compute.retainedPaths.kubernetes-volumes.gid == 0;
    no-implied-application-protection =
      persist.realization.boundary.requiredChildren == [ ]
      && persist.realization.boundary.exclusions == [ ]
      && persist.realization.access == [ ]
      && persist.realization.physicalBacking == null
      && builtins.all (
        route:
        route.semanticRequirements.dataKind == "host-role-state"
        && route.semanticRequirements.requiredConsistency == "filesystem"
        && route.target == null
        && route.integration == null
        && route.guaranteedConsistency == null
        && route.ownerConfig == null
      ) persist.routes
      # Media storage and disposable Incus roots are not additional Preserve States.
      && profile.devices.media.source == "/srv/media"
      && !(lib.hasPrefix persist.realization.path profile.devices.media.source)
      && descriptor.poolPath != compute.stateRoot
      && !(builtins.elem descriptor.poolPath (map (entry: entry.path) retained));
    plan-only-unresolved = builtins.all (
      entry:
      entry.mode == "plan-only"
      && !entry.operational
      && !entry.realization.boundary.recursive
      && builtins.elem "filesystem-read" entry.realization.capabilities
      && builtins.elem "zfs-snapshot" entry.realization.capabilities
      && builtins.elem "zfs-send" entry.realization.capabilities
      && builtins.elem "missing-target" (map (issue: issue.code) (issuesOf entry))
      && !(entry ? caveats)
      && !(entry ? failureDomainIndependent)
    ) inventory.states;
    plan-only-sources-remain-fenced = builtins.all (
      entry:
      builtins.any (
        protected: protected.stateId == entry.stateId && protected.realization == entry.realization
      ) hvn.homelab.preserve.executablePlan.protectedRealizations
    ) inventory.states;
    retained-target-transition =
      builtins.length bothEnabled.executablePlan.states == 2
      && builtins.length retainedTransition.executablePlan.states == 1
      && (builtins.head retainedTransition.executablePlan.states).stateId == "household/home"
      && retainedTransition.executablePlan.protectedTargets == bothEnabled.executablePlan.protectedTargets
      &&
        retainedTransition.desiredInventory.protectedTargets
        == retainedTransition.executablePlan.protectedTargets
      && builtins.all (
        protected:
        protected.routeId == config.den.preserve.routes.household-route.routeId
        && protected.targetId == fenceOwners.targets.retained.targetId
        && protected.targetBoundaries == retainedBoundaries
      ) retainedTransition.executablePlan.protectedTargets;
    missing-empty-targets-remain-refusal-evidence =
      builtins.length missingRetained.executablePlan.states == 1
      && builtins.length missingRetained.executablePlan.protectedTargets == 2
      && builtins.all (
        protected: protected.targetBoundaries == null
      ) missingRetained.executablePlan.protectedTargets
      && builtins.all (
        protected:
        protected.targetBoundaries == {
          paths = [ ];
          nativeLocators = [ ];
        }
      ) emptyRetained.executablePlan.protectedTargets;
    diagnostic-missing-source-keeps-known-targets =
      builtins.length missingSource.desiredInventory.states == 2
      && builtins.all (
        entry: !entry.operational && entry.realization == null
      ) missingSource.desiredInventory.states
      && builtins.length missingSource.executablePlan.protectedTargets == 2
      && builtins.all (
        protected: protected.targetId == "fixture-retained"
      ) missingSource.executablePlan.protectedTargets
      && throws (fenceCompile "enabled" "enabled" retainedBoundaries [ ]);
    malformed-target-diagnostics = builtins.all (
      entry: builtins.elem "invalid-target-boundaries" (map (issue: issue.code) (issuesOf entry))
    ) invalidRetained.desiredInventory.states;
    no-production-enablement =
      hvn.homelab.preserve.executablePlan.states == [ ]
      && !hvn.services.zrepl.enable
      && hvn.services.restic.backups == { };
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) assertions);
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks.preserve-inventory-contracts =
        assert lib.assertMsg (
          failures == [ ]
        ) "Preserve inventory contract assertions failed: ${lib.concatStringsSep ", " failures}";
        pkgs.writeText "preserve-inventory-contracts" "ok\n";
    };
}
