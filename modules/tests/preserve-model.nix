{
  config,
  inputs,
  lib,
  self,
  ...
}:
let
  schemaLib = inputs.gen-schema.lib;
  genMerge = inputs.gen-schema.inputs.gen-merge.lib;

  evaluate =
    declarations:
    let
      evaluated = genMerge.evalModuleTree {
        modules = [
          {
            options.states = schemaLib.mkInstanceRegistry config.den.schema."preserve-state" {
              extraModules = [ { config._identity.keys = [ "stateId" ]; } ];
            };
            options.targets = schemaLib.mkInstanceRegistry config.den.schema."preserve-target" {
              extraModules = [ { config._identity.keys = [ "targetId" ]; } ];
            };
            options.integrations = schemaLib.mkInstanceRegistry config.den.schema."preserve-integration" {
              extraModules = [ { config._identity.keys = [ "integrationId" ]; } ];
            };
            options.routes = schemaLib.mkInstanceRegistry config.den.schema."preserve-route" {
              refs = {
                target = evaluated.config.targets;
                integration = evaluated.config.integrations;
              };
              extraModules = [ { config._identity.keys = [ "routeId" ]; } ];
            };
            config = {
              states = declarations.states or { };
              targets = declarations.targets or { };
              integrations = declarations.integrations or { };
              routes = declarations.routes or { };
            };
          }
        ];
      };
    in
    evaluated.config;

  compile =
    declarations: realizationSpecs:
    let
      evaluated = evaluate declarations;
      realizations = map (spec: {
        state = evaluated.states.${spec.state};
        realization = spec.realization;
      }) realizationSpecs;
    in
    config.fleet.preserve.compile {
      inherit realizations;
      inherit (evaluated)
        states
        targets
        integrations
        routes
        ;
      slots = declarations.slots or { };
      policies = declarations.policies or { };
      scratchDestinations = declarations.scratchDestinations or { };
    };

  throws = value: !(builtins.tryEval (builtins.deepSeq value true)).success;

  boundary = {
    locator = "/srv/app";
    recursive = false;
    requiredChildren = [ ];
    exclusions = [ ];
    consistency = "filesystem";
  };

  realization = {
    kind = "host-filesystem";
    host = "fixture";
    locator = "/srv/app";
    path = "/srv/app";
    package = "/nix/store/application";
    applicationVersion = "1.0";
    capabilities = [ "stable-capture" ];
    inherit boundary;
  };

  realizationSpec = {
    state = "application";
    inherit realization;
  };

  slot = {
    consistency = "filesystem";
    restoreSemantics = "scratch-only";
    suggestedPolicy = "protected";
    caveats = [ "filesystem consistency only" ];
  };

  state = {
    stateId = "application/prod";
    slotId = "application-data";
    mode = "enabled";
    explicitPolicy = "protected";
    selectorPolicies = [ ];
  };

  target = {
    targetId = "shared-archive";
    kind = "archive";
    locator = "/archive/application";
    ownerData = { };
  };

  zreplNative = {
    connect = {
      type = "local";
      listener_name = "fixture-sink";
      client_identity = "fixture-client";
    };
    snapshotting = {
      type = "periodic";
      prefix = "zrepl_";
      interval = "1h";
    };
    pruning = {
      keep_sender = [
        {
          type = "last_n";
          count = 12;
        }
      ];
      keep_receiver = [
        {
          type = "last_n";
          count = 24;
        }
      ];
    };
  };

  resticNative = {
    paths = [ "/srv/app" ];
    exclude = [ "/srv/app/cache" ];
    repository = "/archive/application";
    passwordFile = "/run/credentials/restic-password";
    environmentFile = null;
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
    pruneOpts = [ "--keep-daily 7" ];
    checkOpts = [ "--read-data-subset=1/7" ];
    runCheck = true;
    createWrapper = true;
  };

  source = {
    locator = "/srv/app";
    recursive = false;
    includes = [ ];
    exclusions = [ ];
  };

  binding = native: {
    targetId = "shared-archive";
    inherit source native;
  };

  integration = integrationId: owner: bindings: {
    inherit integrationId owner bindings;
    adapter = "/nix/store/${integrationId}/bin/${integrationId}";
    fixtureOnly = true;
    operations = [ "run" ];
    realizationKinds = [ "host-filesystem" ];
    targetKinds = [ "archive" ];
  };

  common = {
    slots.application-data = slot;
    states.application = state;
    targets.shared = target;
    scratchDestinations.fixture = {
      nativeParent = "scratch/root";
      mountRoot = "/scratch";
    };
    policies.protected = {
      disposable = false;
      routes = [
        "route-zrepl"
        "route-restic"
      ];
    };
    routes = {
      route-zrepl = {
        routeId = "route-zrepl";
        target = "shared";
        integration = "zrepl";
        operation = "run";
        requiredConsistency = "filesystem";
        requiredFidelity = "filesystem";
      };
      route-restic = {
        routeId = "route-restic";
        target = "shared";
        integration = "restic";
        operation = "run";
        requiredConsistency = "filesystem";
        requiredFidelity = "filesystem";
      };
    };
    integrations = {
      zrepl = integration "zrepl-fixture" "zrepl" {
        "application/prod::route-zrepl" = binding zreplNative;
      };
      restic = integration "restic-fixture" "nixos-restic" {
        "application/prod::route-restic" = binding resticNative;
      };
    };
  };

  resolvedEvaluated = evaluate common;
  resolved = compile common [ realizationSpec ];

  ambiguousDeclarations = lib.recursiveUpdate common {
    policies.protected.routes = [ "route-auto" ];
    routes.route-auto = {
      routeId = "route-auto";
      target = "shared";
      integration = null;
      operation = "run";
      requiredConsistency = "filesystem";
      requiredFidelity = "filesystem";
    };
    integrations = {
      zrepl.bindings."application/prod::route-auto" = binding zreplNative;
      restic.bindings."application/prod::route-auto" = binding resticNative;
    };
  };
  ambiguous = compile ambiguousDeclarations [ realizationSpec ];
  selectedAmbiguousDeclarations = lib.recursiveUpdate ambiguousDeclarations {
    routes.route-auto.integration = "zrepl";
  };
  selectedAmbiguous = compile selectedAmbiguousDeclarations [ realizationSpec ];

  oneOwnerDeclarations = lib.recursiveUpdate common {
    policies.protected.routes = [
      "route-a"
      "route-b"
    ];
    routes = {
      route-a = {
        routeId = "route-a";
        target = "shared";
        integration = "zrepl";
        operation = "run";
        requiredConsistency = "filesystem";
        requiredFidelity = "filesystem";
      };
      route-b = {
        routeId = "route-b";
        target = "shared";
        integration = "zrepl";
        operation = "run";
        requiredConsistency = "filesystem";
        requiredFidelity = "filesystem";
      };
    };
    integrations.zrepl.bindings = {
      "application/prod::route-a" = binding zreplNative;
      "application/prod::route-b" = binding zreplNative;
    };
  };
  oneOwner = compile oneOwnerDeclarations [ realizationSpec ];

  singleRoute =
    overrides:
    lib.recursiveUpdate common (
      {
        policies.protected.routes = [ "route-zrepl" ];
      }
      // overrides
    );

  missingTargetDeclarations =
    (singleRoute {
      routes.route-zrepl = {
        target = null;
        integration = null;
      };
    })
    // {
      integrations = { };
    };
  missingTarget = compile missingTargetDeclarations [ realizationSpec ];

  uncoveredRealization = realization // {
    boundary = boundary // {
      requiredChildren = [ "/srv/app/database" ];
    };
  };
  uncoveredDeclarations = singleRoute {
    integrations.zrepl.bindings."application/prod::route-zrepl".source = source;
  };
  uncovered = compile uncoveredDeclarations [
    {
      state = "application";
      realization = uncoveredRealization;
    }
  ];

  excludedDeclarations = singleRoute {
    integrations.zrepl.bindings."application/prod::route-zrepl".source = source // {
      recursive = true;
      exclusions = [ "/srv/app/database" ];
    };
  };
  excluded = compile excludedDeclarations [
    {
      state = "application";
      realization = uncoveredRealization;
    }
  ];

  unsupportedOperationDeclarations = singleRoute {
    routes.route-zrepl.operation = "restore";
  };
  unsupportedOperation = compile unsupportedOperationDeclarations [ realizationSpec ];

  unsupportedRealization = compile (singleRoute { }) [
    {
      state = "application";
      realization = realization // {
        kind = "microvm-storage";
      };
    }
  ];

  zeroOwnerDeclarations =
    (singleRoute {
      routes.route-zrepl.integration = null;
    })
    // {
      integrations = { };
    };
  zeroOwner = compile zeroOwnerDeclarations [ realizationSpec ];

  targetMismatchDeclarations = singleRoute {
    integrations.zrepl.bindings."application/prod::route-zrepl".targetId = "different-target";
  };
  targetMismatch = compile targetMismatchDeclarations [ realizationSpec ];

  missingBindingBase = singleRoute { };
  missingBindingDeclarations = missingBindingBase // {
    integrations = missingBindingBase.integrations // {
      zrepl = missingBindingBase.integrations.zrepl // {
        bindings = { };
      };
    };
  };
  missingBinding = compile missingBindingDeclarations [ realizationSpec ];

  missingRouteDeclarations = lib.recursiveUpdate common {
    policies.protected.routes = [ "absent-route" ];
  };
  missingRoute = compile missingRouteDeclarations [ realizationSpec ];

  missingRealization = compile common [ ];
  duplicateRealization = compile common [
    realizationSpec
    realizationSpec
  ];

  collisionDeclarations = lib.recursiveUpdate common {
    policies.protected.routes = [
      "route-zrepl"
      "route-zrepl"
    ];
  };
  collision = compile collisionDeclarations [ realizationSpec ];

  invalidReferenceDeclarations = lib.recursiveUpdate common {
    routes.route-zrepl.target = "absent-target";
  };

  planOnlyIncompleteDeclarations = lib.recursiveUpdate missingTargetDeclarations {
    states.application.mode = "plan-only";
  };
  planOnlyIncomplete = compile planOnlyIncompleteDeclarations [ realizationSpec ];

  policyDeclarations = {
    slots.application-data = slot // {
      suggestedPolicy = "slot-policy";
    };
    policies = {
      explicit-policy = {
        disposable = true;
        routes = [ ];
      };
      selector-policy = {
        disposable = true;
        routes = [ ];
      };
      slot-policy = {
        disposable = true;
        routes = [ ];
      };
      other-selector = {
        disposable = true;
        routes = [ ];
      };
    };
    states = {
      explicit = state // {
        stateId = "policy/explicit";
        mode = "plan-only";
        explicitPolicy = "explicit-policy";
        selectorPolicies = [
          "selector-policy"
          "other-selector"
        ];
      };
      selector = state // {
        stateId = "policy/selector";
        mode = "plan-only";
        explicitPolicy = null;
        selectorPolicies = [ "selector-policy" ];
      };
      slot = state // {
        stateId = "policy/slot";
        mode = "plan-only";
        explicitPolicy = null;
        selectorPolicies = [ ];
      };
      conflict = state // {
        stateId = "policy/conflict";
        mode = "plan-only";
        explicitPolicy = null;
        selectorPolicies = [
          "selector-policy"
          "other-selector"
        ];
      };
    };
  };
  policySpecs = map (name: {
    state = name;
    inherit realization;
  }) (builtins.attrNames policyDeclarations.states);
  policies = compile policyDeclarations policySpecs;

  platformKinds = [
    "host-filesystem"
    "incus-storage"
    "kubernetes-host-path"
    "kubernetes-pvc"
    "microvm-storage"
    "postgresql"
  ];
  platformDeclarations = {
    slots.application-data = slot // {
      suggestedPolicy = "disposable";
    };
    policies.disposable = {
      disposable = true;
      routes = [ ];
    };
    states = builtins.listToAttrs (
      map (kind: {
        name = kind;
        value = state // {
          stateId = "platform/${kind}";
          mode = "plan-only";
          explicitPolicy = "disposable";
        };
      }) platformKinds
    );
  };
  platformSpecs = map (kind: {
    state = kind;
    realization = realization // {
      inherit kind;
    };
  }) platformKinds;
  platforms = compile platformDeclarations platformSpecs;

  identityDeclarations = lib.recursiveUpdate common {
    states.qa = state // {
      stateId = "application/qa";
    };
  };
  identities = evaluate identityDeclarations;
  stateIdentity = resolvedEvaluated.states.application.id_hash;
  changedPolicyIdentity =
    (evaluate (
      lib.recursiveUpdate common {
        states.application.explicitPolicy = "other-policy";
      }
    )).states.application.id_hash;
  changedOwnerIdentity =
    (evaluate (
      lib.recursiveUpdate common {
        routes.route-zrepl.integration = "restic";
      }
    )).states.application.id_hash;
  changedModeIdentity = (evaluate planOnlyIncompleteDeclarations).states.application.id_hash;
  changedTargetRouteIdentity =
    (evaluate (
      lib.recursiveUpdate common {
        targets.shared.targetId = "replacement-target";
      }
    )).routes.route-zrepl.id_hash;

  changedRealizationIdentities =
    map
      (
        changed:
        let
          result = compile common [
            {
              state = "application";
              realization = realization // changed;
            }
          ];
        in
        (builtins.head result.desiredInventory.states).stateIdentity
      )
      [
        { host = "moved"; }
        {
          kind = "microvm-storage";
          locator = "volume:data";
          path = null;
        }
        { applicationVersion = "2.0"; }
        { package = "/nix/store/new-application"; }
      ];

  issuesOf =
    result:
    lib.concatMap (
      stateResult:
      stateResult.issues ++ lib.concatMap (routeResult: routeResult.issues) stateResult.routes
    ) result.desiredInventory.states;
  hasIssue = code: result: builtins.any (issue: issue.code == code) (issuesOf result);
  allIssueContext =
    result:
    builtins.all (
      issue:
      issue.stateId == "application/prod"
      && lib.hasInfix "state 'application/prod'" issue.message
      && (issue.routeId == null || lib.hasInfix "route '${issue.routeId}'" issue.message)
    ) (issuesOf result);

  routeResults = (builtins.head resolved.desiredInventory.states).routes;
  ambiguousRoutes = (builtins.head ambiguous.desiredInventory.states).routes;
  selectedAmbiguousRoutes = (builtins.head selectedAmbiguous.desiredInventory.states).routes;
  oneOwnerRoutes = (builtins.head oneOwner.desiredInventory.states).routes;
  projection = resolved.ownerProjections;
  zreplJob = builtins.head projection.zrepl.services.zrepl.settings.jobs;
  resticJob = projection.restic.services.restic.backups."preserve-application-prod--route-restic";

  stateById =
    result:
    builtins.listToAttrs (
      map (entry: {
        name = entry.stateId;
        value = entry;
      }) result.states
    );
  policyStates = stateById policies.desiredInventory;

  hvn = self.nixosConfigurations.hvn-hyp1.config;
  realInventory = hvn.homelab.preserve.desiredInventory;
  realStates = stateById realInventory;
  realHomeDataset = hvn.disko.devices.zpool.rpool.datasets."safe/home";
  realPersistDataset = hvn.disko.devices.zpool.rpool.datasets."safe/persist";

  assertions = {
    schema-versions =
      resolved.desiredInventory.schemaVersion == 1
      && resolved.executablePlan.schemaVersion == 1
      && resolved.desiredInventory.kind == "desired-inventory"
      && resolved.executablePlan.kind == "executable-plan";
    explicit-state-identity =
      stateIdentity == changedPolicyIdentity
      && stateIdentity == changedOwnerIdentity
      && stateIdentity == changedModeIdentity
      && builtins.all (identity: identity == stateIdentity) changedRealizationIdentities;
    production-qa-distinct = identities.states.application.id_hash != identities.states.qa.id_hash;
    typed-references =
      resolvedEvaluated.routes.route-zrepl.target.targetId == "shared-archive"
      && resolvedEvaluated.routes.route-zrepl.integration.integrationId == "zrepl-fixture"
      && throws (evaluate invalidReferenceDeclarations).routes.route-zrepl.target;
    policy-precedence =
      policyStates."policy/explicit".policyId == "explicit-policy"
      && policyStates."policy/selector".policyId == "selector-policy"
      && policyStates."policy/slot".policyId == "slot-policy"
      && hasIssue "policy-conflict" policies;
    cascade-evidence =
      resolved.resolutions.inventory.unrun == [ ]
      && resolved.resolutions.inventory.trace.claims != [ ]
      && resolved.resolutions.inventory.trace.resources."route-obligation" != { }
      && resolved.resolutions.inventory.wiring != { };
    plan-only-is-nonoperational =
      builtins.length planOnlyIncomplete.desiredInventory.states == 1
      && (builtins.head planOnlyIncomplete.desiredInventory.states).operational == false
      && planOnlyIncomplete.executablePlan.states == [ ]
      && throws missingTarget.executablePlan;
    realization-failures =
      hasIssue "missing-realization" missingRealization
      && hasIssue "duplicate-realization" duplicateRealization
      && throws missingRealization.executablePlan
      && throws duplicateRealization.executablePlan;
    missing-route = hasIssue "missing-route" missingRoute && allIssueContext missingRoute;
    missing-target = hasIssue "missing-target" missingTarget && allIssueContext missingTarget;
    uncovered-child = hasIssue "uncovered-child-boundary" uncovered && allIssueContext uncovered;
    coverage-exclusion = hasIssue "coverage-exclusion" excluded;
    unsupported-operation =
      hasIssue "unsupported-operation" unsupportedOperation && allIssueContext unsupportedOperation;
    unsupported-realization = hasIssue "unsupported-realization" unsupportedRealization;
    zero-owner = hasIssue "unfulfilled-owner" zeroOwner;
    target-mismatch = hasIssue "target-mismatch" targetMismatch;
    missing-binding = hasIssue "missing-binding" missingBinding;
    resource-collision = throws collision.desiredInventory;
    route-identity-independent =
      resolvedEvaluated.routes.route-zrepl.id_hash == changedTargetRouteIdentity
      && builtins.length routeResults == 2
      && builtins.length (lib.unique (map (route: route.routeId) routeResults)) == 2
      && builtins.length (lib.unique (map (route: route.obligationId) routeResults)) == 2
      && lib.unique (map (route: route.target.targetId) routeResults) == [ "shared-archive" ]
      && builtins.length (lib.unique (map (route: route.integration.integrationId) routeResults)) == 2;
    ambiguous-route-is-one-obligation =
      builtins.length ambiguousRoutes == 1
      && (builtins.head ambiguousRoutes).status == "ambiguous-owner"
      && builtins.length (builtins.head ambiguousRoutes).eligibleIntegrations == 2
      && throws ambiguous.executablePlan
      && builtins.length selectedAmbiguous.executablePlan.states == 1
      && builtins.length selectedAmbiguousRoutes == 1
      && (builtins.head selectedAmbiguousRoutes).status == "resolved"
      && (builtins.head selectedAmbiguousRoutes).integration.integrationId == "zrepl-fixture";
    one-owner-keeps-two-routes =
      builtins.length oneOwnerRoutes == 2
      && builtins.length (lib.unique (map (route: route.routeId) oneOwnerRoutes)) == 2
      && lib.unique (map (route: route.integration.integrationId) oneOwnerRoutes) == [ "zrepl-fixture" ];
    platform-fixtures =
      lib.sort builtins.lessThan (map (entry: entry.realization.kind) platforms.desiredInventory.states)
      == lib.sort builtins.lessThan platformKinds;
    owner-projections =
      projection.zrepl.services.zrepl.enable == false
      && zreplJob.name == "preserve-application-prod--route-zrepl"
      && zreplJob.filesystems."/srv/app"
      && zreplJob.connect.listener_name == "fixture-sink"
      && zreplJob.snapshotting.interval == "1h"
      && (builtins.head zreplJob.pruning.keep_sender).count == 12
      && resticJob.paths == [ "/srv/app" ]
      && resticJob.repository == "/archive/application"
      && resticJob.timerConfig.OnCalendar == "hourly"
      && resticJob.pruneOpts == [ "--keep-daily 7" ]
      && resticJob.checkOpts == [ "--read-data-subset=1/7" ]
      && resticJob.runCheck
      && builtins.all (key: !(builtins.elem key (builtins.attrNames zreplJob))) [
        "capture"
        "protect"
        "release"
        "retry"
      ];
    real-inventory =
      builtins.attrNames realStates == [
        "household/home"
        "household/persist"
      ]
      && realStates."household/home".realization.path == realHomeDataset.mountpoint
      && realStates."household/home".realization.locator == "rpool/safe/home"
      && realStates."household/persist".realization.path == realPersistDataset.mountpoint
      && realStates."household/persist".realization.locator == "rpool/safe/persist"
      && builtins.all (
        entry:
        entry.mode == "plan-only"
        && !entry.operational
        && !entry.realization.boundary.recursive
        && builtins.elem "missing-target" (
          map (issue: issue.code) (issuesOf {
            desiredInventory.states = [ entry ];
          })
        )
        && builtins.length entry.caveats == 2
      ) realInventory.states;
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
      checks.preserve-model =
        assert lib.assertMsg (
          failures == [ ]
        ) "Preserve model assertions failed: ${lib.concatStringsSep ", " failures}";
        pkgs.writeText "preserve-model" "ok\n";
    };
}
