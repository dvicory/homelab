{
  config,
  inputs,
  lib,
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
            options.slots = schemaLib.mkInstanceRegistry config.den.schema."preserve-slot" {
              refs.suggestedPolicy = evaluated.config.policies;
              extraModules = [ { config._identity.keys = [ "slotId" ]; } ];
            };
            options.states = schemaLib.mkInstanceRegistry config.den.schema."preserve-state" {
              refs = {
                slot = evaluated.config.slots;
                explicitPolicy = evaluated.config.policies;
                selectorPolicies = evaluated.config.policies;
              };
              extraModules = [ { config._identity.keys = [ "stateId" ]; } ];
            };
            options.policies = schemaLib.mkInstanceRegistry config.den.schema."preserve-policy" {
              refs.routes = evaluated.config.routes;
              extraModules = [ { config._identity.keys = [ "policyId" ]; } ];
            };
            options.routes = schemaLib.mkInstanceRegistry config.den.schema."preserve-route" {
              refs = {
                target = evaluated.config.targets;
                integration = evaluated.config.integrations;
              };
              extraModules = [ { config._identity.keys = [ "routeId" ]; } ];
            };
            options.targets = schemaLib.mkInstanceRegistry config.den.schema."preserve-target" {
              extraModules = [ { config._identity.keys = [ "targetId" ]; } ];
            };
            options.integrations = schemaLib.mkInstanceRegistry config.den.schema."preserve-integration" {
              extraModules = [ { config._identity.keys = [ "integrationId" ]; } ];
            };
            config = {
              slots = declarations.slots or { };
              states = declarations.states or { };
              policies = declarations.policies or { };
              routes = declarations.routes or { };
              targets = declarations.targets or { };
              integrations = declarations.integrations or { };
            };
          }
        ];
      };
    in
    evaluated.config;

  emptySource = {
    subpath = null;
    include = [ ];
    exclude = [ ];
  };

  compile =
    declarations: realizationSpecs:
    let
      evaluated = evaluate declarations;
      realizations = map (spec: {
        state = evaluated.states.${spec.state};
        realization = spec.realization;
      }) realizationSpecs;
      bindings = map (
        spec:
        spec
        // {
          state = evaluated.states.${spec.state};
          route = evaluated.routes.${spec.route};
          integration = if spec ? integration then evaluated.integrations.${spec.integration} else null;
          source = spec.source or emptySource;
          nativeOverrides = spec.nativeOverrides or { };
        }
      ) (declarations.bindings or [ ]);
      integrationTargets = map (
        spec:
        spec
        // {
          integration = evaluated.integrations.${spec.integration};
          target = evaluated.targets.${spec.target};
          native = spec.native or { };
        }
      ) (declarations.integrationTargets or [ ]);
    in
    config.fleet.preserve.compile {
      inherit realizations bindings integrationTargets;
      inherit (evaluated)
        states
        slots
        policies
        routes
        targets
        integrations
        ;
      scratchDestinations = declarations.scratchDestinations or { };
      projectors = declarations.projectors or config.fleet.preserve.projectors;
      fixtureOnly = declarations.fixtureOnly or true;
    };

  throws = value: !(builtins.tryEval (builtins.deepSeq value true)).success;

  boundary = {
    recursive = false;
    requiredChildren = [ ];
    exclusions = [ ];
  };

  zfsRealization = {
    kind = "zfs-dataset";
    owner = {
      kind = "host";
      id = "fixture";
    };
    locator = "source/app";
    path = "/srv/app";
    capabilities = [
      "filesystem-read"
      "zfs-snapshot"
      "zfs-send"
    ];
    inherit boundary;
    access = [ ];
    physicalBacking = null;
  };

  realizationSpec = {
    state = "application";
    realization = zfsRealization;
  };

  slot = {
    slotId = "application-data";
    dataKind = "application";
    requiredConsistency = "live";
    requiredFidelity = [ "posix-filesystem" ];
    acceptedPayloadFormats = [ ];
  };

  state = {
    stateId = "application/prod";
    slot = "application-data";
    mode = "enabled";
    explicitPolicy = "protected";
    selectorPolicies = [ ];
  };

  target = {
    targetId = "house-backup";
    failureDomain = {
      site = "fixture";
      domain = "one-domain";
    };
  };

  mkIntegration =
    integrationId: owner: extra:
    {
      inherit integrationId owner;
      adapter = "/nix/store/${integrationId}/bin/${integrationId}";
      fixtureOnly = true;
      operations = [ "run" ];
      payloadRepresentation = "posix-filesystem";
    }
    // extra;

  zreplIntegration = mkIntegration "zrepl" "zrepl" {
    dataKinds = [ "application" ];
    requiredSourceCapabilities = [
      "zfs-snapshot"
      "zfs-send"
    ];
    guaranteedConsistency = "filesystem";
    fidelityGuarantees = [
      "posix-filesystem"
      "zfs-dataset"
    ];
    nativePointRepresentations = [
      "openzfs.snapshot"
      "openzfs.send-stream"
    ];
    realizationKindConstraints = [ "zfs-dataset" ];
  };

  resticIntegration = mkIntegration "nixos-restic" "restic" {
    dataKinds = [ "*" ];
    requiredSourceCapabilities = [ "filesystem-read" ];
    guaranteedConsistency = "live";
    fidelityGuarantees = [ "posix-filesystem" ];
    nativePointRepresentations = [ "restic.snapshot/v1" ];
    realizationKindConstraints = [ ];
  };

  common = {
    slots.application-data = slot;
    states.application = state;
    policies.protected = {
      policyId = "protected";
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
        requiredFidelity = [ "zfs-dataset" ];
      };
      route-restic = {
        routeId = "route-restic";
        target = "shared";
        integration = "restic";
        operation = "run";
        requiredConsistency = "live";
        requiredFidelity = [ "posix-filesystem" ];
      };
    };
    targets.shared = target;
    integrations = {
      zrepl = zreplIntegration;
      restic = resticIntegration;
    };
    integrationTargets = [
      {
        integration = "zrepl";
        target = "shared";
        native.zrepl = {
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
      }
      {
        integration = "restic";
        target = "shared";
        native.restic = {
          target = {
            repository = "/archive/application";
            passwordFile = "/run/credentials/restic-password";
          };
          timerConfig = {
            OnCalendar = "hourly";
            Persistent = true;
          };
          pruneOpts = [ "--keep-daily 7" ];
          checkOpts = [ "--read-data-subset=1/7" ];
          runCheck = true;
        };
      }
    ];
    scratchDestinations.fixture = {
      nativeParent = "scratch/root";
      mountRoot = "/scratch";
    };
  };

  resolvedEvaluated = evaluate common;
  resolved = compile common [ realizationSpec ];

  singleRoute =
    overrides:
    lib.recursiveUpdate common (
      {
        policies.protected.routes = [ "route-zrepl" ];
      }
      // overrides
    );

  # The mutable Restic traversal candidate guarantees only `live` and cannot
  # satisfy a StateSlot that requires `filesystem`.
  weakResticDeclarations = lib.recursiveUpdate common {
    slots.application-data.requiredConsistency = "filesystem";
    policies.protected.routes = [ "route-restic" ];
    routes.route-restic.requiredConsistency = "filesystem";
  };
  weakRestic = compile weakResticDeclarations [ realizationSpec ];

  # An owner-managed Restic profile that explicitly guarantees `filesystem`
  # satisfies the same route.
  strongResticDeclarations = lib.recursiveUpdate weakResticDeclarations {
    integrations.restic.guaranteedConsistency = "filesystem";
  };
  strongRestic = compile strongResticDeclarations [ realizationSpec ];

  weakRouteConsistencyDeclarations = lib.recursiveUpdate common {
    slots.application-data.requiredConsistency = "filesystem";
    policies.protected.routes = [ "route-zrepl" ];
    routes.route-zrepl.requiredConsistency = "live";
  };
  weakRouteConsistency = compile weakRouteConsistencyDeclarations [ realizationSpec ];

  ambiguousDeclarations = lib.recursiveUpdate common {
    policies.protected.routes = [ "route-auto" ];
    routes.route-auto = {
      routeId = "route-auto";
      target = "shared";
      integration = null;
      operation = "run";
      requiredConsistency = "live";
      requiredFidelity = [ "posix-filesystem" ];
    };
  };
  ambiguous = compile ambiguousDeclarations [ realizationSpec ];
  selectedAmbiguous = compile (lib.recursiveUpdate ambiguousDeclarations {
    routes.route-auto.integration = "zrepl";
  }) [ realizationSpec ];
  bindingSelected = compile (
    ambiguousDeclarations
    // {
      bindings = [
        {
          state = "application";
          route = "route-auto";
          integration = "zrepl";
        }
      ];
    }
  ) [ realizationSpec ];

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
        requiredFidelity = [ "zfs-dataset" ];
      };
      route-b = {
        routeId = "route-b";
        target = "shared";
        integration = "zrepl";
        operation = "run";
        requiredConsistency = "filesystem";
        requiredFidelity = [ "zfs-dataset" ];
      };
    };
  };
  oneOwner = compile oneOwnerDeclarations [ realizationSpec ];

  missingTargetDeclarations = singleRoute {
    routes.route-zrepl = {
      target = null;
      integration = null;
    };
  };
  missingTarget = compile missingTargetDeclarations [ realizationSpec ];

  uncoveredRealization = zfsRealization // {
    boundary = boundary // {
      requiredChildren = [ "/srv/app/database" ];
    };
  };
  uncovered = compile (singleRoute { }) [
    {
      state = "application";
      realization = uncoveredRealization;
    }
  ];

  coveredRealization = zfsRealization // {
    boundary = boundary // {
      recursive = true;
      requiredChildren = [ "/srv/app/database" ];
    };
  };
  excluded =
    compile
      (singleRoute {
        bindings = [
          {
            state = "application";
            route = "route-zrepl";
            source.exclude = [ "/srv/app/database" ];
          }
        ];
      })
      [
        {
          state = "application";
          realization = coveredRealization;
        }
      ];

  unsupportedOperation = compile (singleRoute {
    routes.route-zrepl.operation = "restore";
  }) [ realizationSpec ];

  unsupportedCapability = compile (singleRoute {
    integrations.zrepl.requiredSourceCapabilities = [ "zfs-receive" ];
  }) [ realizationSpec ];

  unsupportedKind = compile (singleRoute {
    integrations.zrepl.realizationKindConstraints = [ "host-path" ];
  }) [ realizationSpec ];

  unsupportedDataKind = compile (singleRoute {
    integrations.zrepl.dataKinds = [ "database" ];
  }) [ realizationSpec ];

  unsupportedFidelity = compile (singleRoute {
    routes.route-zrepl.requiredFidelity = [ "application-quiesced" ];
  }) [ realizationSpec ];

  unsupportedPayload = compile (singleRoute {
    slots.application-data.acceptedPayloadFormats = [ "sql-dump" ];
    integrations.zrepl.payloadRepresentation = "sql-dump";
  }) [ realizationSpec ];
  mismatchedPayload = compile (singleRoute {
    slots.application-data.acceptedPayloadFormats = [ "sql-dump" ];
    integrations.zrepl.payloadRepresentation = null;
  }) [ realizationSpec ];

  zeroOwner = compile (lib.recursiveUpdate (singleRoute {
    routes.route-zrepl.integration = null;
  }) { integrationTargets = [ ]; }) [ realizationSpec ];

  missingWiring = compile (singleRoute {
    integrationTargets = [
      {
        integration = "restic";
        target = "shared";
      }
    ];
  }) [ realizationSpec ];

  duplicateWiring = compile (singleRoute {
    integrationTargets = [
      {
        integration = "zrepl";
        target = "shared";
      }
      {
        integration = "zrepl";
        target = "shared";
      }
    ];
  }) [ realizationSpec ];

  duplicateBinding = compile (singleRoute {
    bindings = [
      {
        state = "application";
        route = "route-zrepl";
      }
      {
        state = "application";
        route = "route-zrepl";
      }
    ];
  }) [ realizationSpec ];

  contradictoryBinding = compile (singleRoute {
    bindings = [
      {
        state = "application";
        route = "route-zrepl";
        integration = "restic";
      }
    ];
  }) [ realizationSpec ];

  forbiddenOverride = compile (singleRoute {
    bindings = [
      {
        state = "application";
        route = "route-zrepl";
        nativeOverrides.paths = [ "/srv/app" ];
      }
    ];
  }) [ realizationSpec ];

  forbiddenSharedNative = compile (singleRoute {
    integrationTargets = [
      {
        integration = "zrepl";
        target = "shared";
        native.target = "backup/receive";
      }
    ];
  }) [ realizationSpec ];

  narrowed = compile (singleRoute {
    policies.protected.routes = [ "route-restic" ];
    bindings = [
      {
        state = "application";
        route = "route-restic";
        source = {
          subpath = "db";
          include = [ "/srv/app/extra" ];
          exclude = [ "/srv/app/tmp" ];
        };
        nativeOverrides.restic.tags = [ "edge" ];
      }
    ];
  }) [ realizationSpec ];

  collisionDeclarations = singleRoute {
    policies.protected.routes = [
      "route-zrepl"
      "route-zrepl"
    ];
  };
  collision = compile collisionDeclarations [ realizationSpec ];

  invalidReferenceDeclarations = singleRoute {
    routes.route-zrepl.target = "absent-target";
  };

  invalidSlotFieldDeclarations = {
    slots.application-data = slot // {
      nativePointRepresentations = [ "restic.snapshot/v1" ];
      caveats = [ "removed field" ];
    };
  };

  invalidRouteFieldDeclarations = lib.recursiveUpdate common {
    routes.route-zrepl.requiredNativePointRepresentations = [ "openzfs.snapshot" ];
  };

  invalidTargetFieldDeclarations = lib.recursiveUpdate common {
    targets.shared.purpose = "fixture recovery";
  };

  invalidIntegrationFieldDeclarations = lib.recursiveUpdate common {
    integrations.zrepl = zreplIntegration // {
      realizationKinds = [ "zfs-dataset" ];
      explicitScratch = true;
      acceptedPayloadFormats = [ "sql-dump" ];
    };
  };

  authoritativeBacking = compile common [
    {
      state = "application";
      realization = zfsRealization // {
        physicalBacking = {
          authoritative = false;
          kind = "kubernetes-local-volume";
        };
      };
    }
  ];

  emptyFailureDomain = compile (
    common
    // {
      targets = common.targets // {
        shared = target // {
          failureDomain = { };
        };
      };
    }
  ) [ realizationSpec ];

  malformedRealization = compile common [
    {
      state = "application";
      realization = removeAttrs zfsRealization [ "access" ];
    }
  ];

  malformedOwner = compile common [
    {
      state = "application";
      realization = zfsRealization // {
        owner = {
          kind = "host";
        };
      };
    }
  ];

  foreignEvaluated = evaluate {
    integrations.alien = mkIntegration "alien" "alien" {
      dataKinds = [ "*" ];
      requiredSourceCapabilities = [ ];
      guaranteedConsistency = "live";
      fidelityGuarantees = [ ];
      nativePointRepresentations = [ "alien/v1" ];
      realizationKindConstraints = [ ];
    };
  };

  foreignCompile =
    bindings: integrationTargets:
    config.fleet.preserve.compile {
      inherit (resolvedEvaluated)
        states
        slots
        policies
        routes
        targets
        integrations
        ;
      inherit bindings integrationTargets;
      scratchDestinations = { };
      realizations = [
        {
          state = resolvedEvaluated.states.application;
          realization = zfsRealization;
        }
      ];
      projectors = { };
      fixtureOnly = true;
    };

  foreignWiring =
    foreignCompile
      [ ]
      [
        {
          integration = foreignEvaluated.integrations.alien;
          target = resolvedEvaluated.targets.shared;
          native = { };
        }
      ];

  foreignBinding =
    foreignCompile
      [
        {
          state = resolvedEvaluated.states.application;
          route = resolvedEvaluated.routes.route-zrepl;
          integration = foreignEvaluated.integrations.alien;
          source = emptySource;
          nativeOverrides = { };
        }
      ]
      [ ];

  nativelessWiring = compile (singleRoute {
    integrationTargets = [
      {
        integration = "zrepl";
        target = "shared";
      }
    ];
  }) [ realizationSpec ];

  uncredentialedRestic = compile (singleRoute {
    policies.protected.routes = [ "route-restic" ];
    integrationTargets = [
      {
        integration = "restic";
        target = "shared";
        native.restic = { };
      }
    ];
  }) [ realizationSpec ];

  dualRepositoryRestic = compile (singleRoute {
    policies.protected.routes = [ "route-restic" ];
    integrationTargets = [
      {
        integration = "restic";
        target = "shared";
        native.restic.target = {
          repository = "/archive/application";
          repositoryFile = "/run/secrets/restic-repository";
          passwordFile = "/run/credentials/restic-password";
        };
      }
    ];
  }) [ realizationSpec ];

  nonFixtureExecutable = compile (
    common
    // {
      fixtureOnly = false;
    }
  ) [ realizationSpec ];

  planOnlyIncompleteDeclarations = lib.recursiveUpdate missingTargetDeclarations {
    states.application.mode = "plan-only";
  };
  planOnlyIncomplete = compile planOnlyIncompleteDeclarations [ realizationSpec ];

  missingRealization = compile common [ ];
  duplicateRealization = compile common [
    realizationSpec
    realizationSpec
  ];

  missingPolicyDeclarations = lib.recursiveUpdate common {
    states.application.explicitPolicy = null;
  };
  missingPolicy = compile missingPolicyDeclarations [ realizationSpec ];

  invalidDisposableDeclarations = lib.recursiveUpdate common {
    policies.protected.disposable = true;
  };
  invalidDisposable = compile invalidDisposableDeclarations [ realizationSpec ];

  policyDeclarations = {
    slots.application-data = slot // {
      suggestedPolicy = "slot-policy";
    };
    policies = {
      explicit-policy = {
        policyId = "explicit-policy";
        disposable = true;
        routes = [ ];
      };
      selector-policy = {
        policyId = "selector-policy";
        disposable = true;
        routes = [ ];
      };
      slot-policy = {
        policyId = "slot-policy";
        disposable = true;
        routes = [ ];
      };
      other-selector = {
        policyId = "other-selector";
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
    realization = zfsRealization;
  }) (builtins.attrNames policyDeclarations.states);
  policies = compile policyDeclarations policySpecs;

  platformSpecs = [
    {
      state = "container";
      realization = zfsRealization // {
        kind = "container-rootfs";
        access = [
          {
            kind = "container";
            name = "application";
          }
        ];
      };
    }
    {
      state = "incus";
      realization = zfsRealization // {
        kind = "incus-local-volume";
        access = [
          {
            kind = "incus";
            instance = "database";
            device = "data";
          }
        ];
      };
    }
    {
      state = "kube-pv";
      realization = zfsRealization // {
        kind = "kubernetes-local-volume";
        access = [
          {
            kind = "kubernetes-local-pv";
            hostPath = "/var/lib/application";
          }
          {
            kind = "kubernetes-host-path";
            hostPath = "/srv/application";
          }
        ];
      };
    }
    {
      state = "kube-pvc";
      realization = zfsRealization // {
        kind = "csi-pvc";
        access = [
          {
            kind = "kubernetes-pvc";
            claim = "data-application";
          }
        ];
      };
    }
    {
      state = "microvm";
      realization = zfsRealization // {
        kind = "microvm-share";
        access = [
          {
            kind = "microvm";
            share = "state";
          }
          {
            kind = "microvm";
            volume = "state-volume";
          }
        ];
      };
    }
  ];
  platformDeclarations = {
    slots.application-data = slot // {
      suggestedPolicy = "disposable";
    };
    policies.disposable = {
      policyId = "disposable";
      disposable = true;
      routes = [ ];
    };
    states = builtins.listToAttrs (
      map (spec: {
        name = spec.state;
        value = state // {
          stateId = "platform/${spec.state}";
          mode = "plan-only";
          explicitPolicy = "disposable";
        };
      }) platformSpecs
    );
  };
  platforms = compile platformDeclarations platformSpecs;

  postgresDeclarations = {
    slots.database = slot // {
      slotId = "database";
      dataKind = "database";
      requiredFidelity = [ ];
    };
    policies.protected = {
      policyId = "protected";
      routes = [ "route-probe" ];
    };
    routes.route-probe = {
      routeId = "route-probe";
      target = "shared";
      integration = "prober";
      operation = "run";
    };
    targets.shared = target;
    integrations.prober = mkIntegration "filesystem-prober" "fixture" {
      dataKinds = [ "database" ];
      requiredSourceCapabilities = [ "filesystem-read" ];
      guaranteedConsistency = "live";
      fidelityGuarantees = [ ];
      nativePointRepresentations = [ "fixture.probe" ];
      realizationKindConstraints = [ ];
    };
    integrationTargets = [
      {
        integration = "prober";
        target = "shared";
      }
    ];
    states.postgres = state // {
      stateId = "platform/postgres";
      slot = "database";
      mode = "enabled";
      explicitPolicy = "protected";
    };
  };
  postgresRealization = {
    kind = "postgresql-cluster";
    owner = {
      kind = "kubernetes";
      id = "database-0";
    };
    locator = "postgresql://database-0";
    path = null;
    capabilities = [ "postgresql-export" ];
    inherit boundary;
    access = [ ];
    physicalBacking = {
      kind = "kubernetes-local-volume";
      hostPath = "/var/lib/postgres/data";
      capabilities = [
        "filesystem-read"
        "zfs-snapshot"
      ];
    };
  };
  postgres = compile postgresDeclarations [
    {
      state = "postgres";
      realization = postgresRealization;
    }
  ];

  identityDeclarations = lib.recursiveUpdate common {
    states.alt = state;
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
        policies.other-policy = {
          policyId = "other-policy";
          disposable = true;
          routes = [ ];
        };
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
              realization = zfsRealization // changed;
            }
          ];
        in
        (builtins.head result.desiredInventory.states).stateIdentity
      )
      [
        {
          owner = {
            kind = "host";
            id = "moved";
          };
        }
        {
          kind = "microvm-share";
          locator = "volume:data";
          path = null;
        }
        {
          access = [
            {
              kind = "container";
              name = "application";
            }
          ];
        }
        {
          capabilities = [ "filesystem-read" ];
        }
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

  stateById =
    result:
    builtins.listToAttrs (
      map (entry: {
        name = entry.stateId;
        value = entry;
      }) result.states
    );
  routeById =
    routes: routeId: builtins.head (builtins.filter (route: route.routeId == routeId) routes);

  policyStates = stateById policies.desiredInventory;
  resolvedStates = stateById resolved.desiredInventory;
  resolvedEntry = resolvedStates."application/prod";
  zreplRoute = routeById resolvedEntry.routes "route-zrepl";
  resticRoute = routeById resolvedEntry.routes "route-restic";
  ambiguousRoutes = (builtins.head ambiguous.desiredInventory.states).routes;
  selectedAmbiguousRoutes = (builtins.head selectedAmbiguous.desiredInventory.states).routes;
  bindingSelectedRoutes = (builtins.head bindingSelected.desiredInventory.states).routes;
  oneOwnerRoutes = (builtins.head oneOwner.desiredInventory.states).routes;
  narrowedRoute = routeById (builtins.head narrowed.desiredInventory.states).routes "route-restic";

  projections = resolved.ownerProjections;
  zreplProjection = projections.${zreplRoute.obligationId};
  resticProjection = projections.${resticRoute.obligationId};
  zreplJob = builtins.head zreplProjection.config.services.zrepl.settings.jobs;
  resticBackups = resticProjection.config.services.restic.backups;
  resticJob = resticBackups.${builtins.head (builtins.attrNames resticBackups)};

  narrowedProjections = narrowed.ownerProjections;
  narrowedProjection = narrowedProjections.${narrowedRoute.obligationId};
  narrowedBackups = narrowedProjection.config.services.restic.backups;
  narrowedJob = narrowedBackups.${builtins.head (builtins.attrNames narrowedBackups)};

  misleadingOwner = compile (lib.recursiveUpdate common {
    integrations.zrepl.owner = "restic";
  }) [ realizationSpec ];
  misleadingZreplRoute = routeById (builtins.head misleadingOwner.desiredInventory.states).routes "route-zrepl";
  misleadingProjection = misleadingOwner.ownerProjections.${misleadingZreplRoute.obligationId};

  platformStates = stateById platforms.desiredInventory;
  postgresEntry = (builtins.head postgres.desiredInventory.states);

  assertions = {
    schema-versions =
      resolved.desiredInventory.schemaVersion == 1
      && resolved.executablePlan.schemaVersion == 1
      && resolved.desiredInventory.kind == "desired-inventory"
      && resolved.executablePlan.kind == "executable-plan"
      && resolved.desiredInventory.fixtureOnly == true
      && resolved.executablePlan.fixtureOnly == true;
    typed-identities =
      builtins.isString stateIdentity
      && builtins.isString resolvedEvaluated.slots.application-data.id_hash
      && builtins.isString resolvedEvaluated.policies.protected.id_hash
      && builtins.isString resolvedEvaluated.targets.shared.id_hash
      && builtins.isString resolvedEvaluated.integrations.zrepl.id_hash
      && builtins.isString zreplRoute.routeIdentity
      && zreplRoute.obligationId != resticRoute.obligationId;
    placement-independent-identity = identities.states.alt.id_hash == stateIdentity;
    explicit-state-identity =
      stateIdentity == changedPolicyIdentity
      && stateIdentity == changedOwnerIdentity
      && stateIdentity == changedModeIdentity
      && builtins.all (identity: identity == stateIdentity) changedRealizationIdentities;
    production-qa-distinct = identities.states.application.id_hash != identities.states.qa.id_hash;
    typed-references =
      resolvedEvaluated.routes.route-zrepl.target.targetId == "house-backup"
      && resolvedEvaluated.routes.route-zrepl.integration.integrationId == "zrepl"
      && resolvedEvaluated.states.application.slot.slotId == "application-data"
      && throws (evaluate invalidReferenceDeclarations).routes.route-zrepl.target;
    strict-schema-fields =
      throws (evaluate invalidSlotFieldDeclarations).slots.application-data
      && throws (evaluate invalidRouteFieldDeclarations).routes.route-zrepl
      && throws (evaluate invalidTargetFieldDeclarations).targets.shared
      && throws (evaluate invalidIntegrationFieldDeclarations).integrations.zrepl;
    policy-precedence =
      policyStates."policy/explicit".policyId == "explicit-policy"
      && policyStates."policy/selector".policyId == "selector-policy"
      && policyStates."policy/slot".policyId == "slot-policy"
      && hasIssue "policy-conflict" policies
      && hasIssue "missing-policy" missingPolicy
      && hasIssue "invalid-disposable-policy" invalidDisposable;
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
    missing-target = hasIssue "missing-target" missingTarget && allIssueContext missingTarget;
    coverage =
      hasIssue "uncovered-child-boundary" uncovered
      && allIssueContext uncovered
      && hasIssue "coverage-exclusion" excluded;
    capability-matrix =
      hasIssue "unsupported-operation" unsupportedOperation
      && hasIssue "unsupported-capability" unsupportedCapability
      && hasIssue "unsupported-realization-kind" unsupportedKind
      && hasIssue "unsupported-data-kind" unsupportedDataKind
      && hasIssue "unsupported-fidelity" unsupportedFidelity
      && hasIssue "unsupported-payload-format" mismatchedPayload;
    payload-selection =
      !(hasIssue "unsupported-payload-format" unsupportedPayload)
      &&
        (routeById (builtins.head unsupportedPayload.desiredInventory.states).routes "route-zrepl")
        .payloadRepresentation == "sql-dump";
    consistency-matrix =
      hasIssue "unsupported-consistency" weakRestic
      && hasIssue "weak-route-consistency" weakRouteConsistency
      && !(hasIssue "unsupported-consistency" strongRestic)
      &&
        (routeById (builtins.head strongRestic.desiredInventory.states).routes "route-restic").status
        == "resolved";
    binding-rules =
      hasIssue "duplicate-binding" duplicateBinding
      && hasIssue "contradictory-binding" contradictoryBinding
      && hasIssue "contradictory-binding" forbiddenOverride
      && hasIssue "contradictory-binding" forbiddenSharedNative;
    wiring-rules =
      hasIssue "missing-integration-target" missingWiring
      && hasIssue "duplicate-integration-target" duplicateWiring
      && hasIssue "unfulfilled-owner" zeroOwner;
    route-identity-independent =
      resolvedEvaluated.routes.route-zrepl.id_hash == changedTargetRouteIdentity
      && builtins.length resolvedEntry.routes == 2
      && builtins.length (lib.unique (map (route: route.routeId) resolvedEntry.routes)) == 2
      && builtins.length (lib.unique (map (route: route.obligationId) resolvedEntry.routes)) == 2
      && lib.unique (map (route: route.target.targetId) resolvedEntry.routes) == [ "house-backup" ]
      &&
        builtins.length (lib.unique (map (route: route.integration.integrationId) resolvedEntry.routes))
        == 2;
    shared-target-not-independent =
      !(zreplRoute ? failureDomainIndependent)
      && !(resticRoute ? failureDomainIndependent)
      && zreplRoute.target.failureDomain == resticRoute.target.failureDomain
      && zreplRoute.target.failureDomain.domain == "one-domain"
      && !(zreplRoute.target ? purpose)
      && !(zreplRoute.target ? locator);
    resolved-routes =
      zreplRoute.status == "resolved"
      && resticRoute.status == "resolved"
      && zreplRoute.integration.integrationId == "zrepl"
      && resticRoute.integration.integrationId == "nixos-restic"
      && zreplRoute.guaranteedConsistency == "filesystem"
      && resticRoute.guaranteedConsistency == "live"
      && resticRoute.nativePointRepresentations == [ "restic.snapshot/v1" ]
      && resticRoute.payloadRepresentation == "posix-filesystem"
      && !(resticRoute.integration ? explicitScratch)
      && !(resticRoute ? binding)
      && !(resticRoute ? bindingApplied)
      && !(resticRoute.ownerConfig ? bindingApplied)
      && !(resticRoute ? requiredConsistency)
      && !(resticRoute ? requiredFidelity)
      && !(resticRoute ? caveats)
      && zreplRoute.semanticRequirements.dataKind == "application"
      && zreplRoute.semanticRequirements.requiredConsistency == "live"
      && zreplRoute.semanticRequirements.routeRequiredConsistency == "filesystem"
      &&
        zreplRoute.semanticRequirements.requiredFidelity == [
          "posix-filesystem"
          "zfs-dataset"
        ]
      && resticRoute.semanticRequirements.routeRequiredConsistency == "live"
      && resticRoute.semanticRequirements.acceptedPayloadFormats == [ ]
      && zreplRoute.ownerConfig.native.zrepl.connect.listener_name == "fixture-sink"
      && resticRoute.ownerConfig.native.restic.target.repository == "/archive/application"
      && builtins.length resolved.executablePlan.states == 1;
    narrowed-binding =
      narrowedRoute.status == "resolved"
      && narrowedRoute.ownerConfig != null
      && narrowedRoute.ownerConfig.source.subpath == "db"
      && narrowedRoute.ownerConfig.native.restic.tags == [ "edge" ]
      &&
        narrowedJob.paths == [
          "/srv/app/db"
          "/srv/app/extra"
        ]
      && narrowedJob.exclude == [ "/srv/app/tmp" ]
      && narrowedJob.repository == "/archive/application";
    ambiguous-route-is-one-obligation =
      builtins.length ambiguousRoutes == 1
      && (builtins.head ambiguousRoutes).status == "ambiguous-owner"
      && builtins.length (builtins.head ambiguousRoutes).eligibleIntegrations == 2
      && throws ambiguous.executablePlan
      && builtins.length selectedAmbiguousRoutes == 1
      && (builtins.head selectedAmbiguousRoutes).status == "resolved"
      && (builtins.head selectedAmbiguousRoutes).integration.integrationId == "zrepl"
      && builtins.length bindingSelectedRoutes == 1
      && (builtins.head bindingSelectedRoutes).status == "resolved"
      && (builtins.head bindingSelectedRoutes).integration.integrationId == "zrepl";
    one-owner-keeps-two-routes =
      builtins.length oneOwnerRoutes == 2
      && builtins.length (lib.unique (map (route: route.routeId) oneOwnerRoutes)) == 2
      && builtins.length (lib.unique (map (route: route.obligationId) oneOwnerRoutes)) == 2
      && lib.unique (map (route: route.integration.integrationId) oneOwnerRoutes) == [ "zrepl" ]
      && builtins.all (route: route.status == "resolved") oneOwnerRoutes;
    platform-access-fixtures =
      builtins.length platforms.desiredInventory.states == 5
      && builtins.all (
        entry: entry.realization != null && builtins.isList entry.realization.access
      ) platforms.desiredInventory.states
      && platformStates."platform/kube-pv".realization.kind == "kubernetes-local-volume"
      && builtins.length platformStates."platform/kube-pv".realization.access == 2
      && builtins.length platformStates."platform/microvm".realization.access == 2;
    physical-backing =
      postgresEntry.realization.physicalBacking.hostPath == "/var/lib/postgres/data"
      && !(postgresEntry.realization.physicalBacking ? authoritative)
      && hasIssue "unsupported-capability" postgres
      && throws authoritativeBacking.desiredInventory;
    owner-projections =
      zreplProjection.integrationId == "zrepl"
      && zreplProjection.stateId == "application/prod"
      && zreplProjection.routeId == "route-zrepl"
      && zreplProjection.targetId == "house-backup"
      && zreplProjection.entryPoint == "/nix/store/zrepl/bin/zrepl"
      && lib.hasPrefix "preserve-" (
        builtins.head (map (job: job.name) zreplProjection.config.services.zrepl.settings.jobs)
      )
      && zreplProjection.config.services.zrepl.enable == false
      && zreplJob.filesystems."source/app"
      && zreplJob.connect.listener_name == "fixture-sink"
      && zreplJob.snapshotting.interval == "1h"
      && (builtins.head zreplJob.pruning.keep_sender).count == 12
      && resticProjection.integrationId == "nixos-restic"
      && resticProjection.targetId == "house-backup"
      && resticProjection.entryPoint == "/nix/store/nixos-restic/bin/nixos-restic"
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
    no-owner-switch =
      misleadingProjection.config ? services
      && misleadingProjection.config.services ? zrepl
      && misleadingProjection.config.services.zrepl.settings.jobs != [ ];
    fixture-only-enforcement =
      nonFixtureExecutable.desiredInventory.fixtureOnly == false
      && hasIssue "fixture-only-integration" nonFixtureExecutable
      && throws nonFixtureExecutable.executablePlan;
    input-validation =
      throws emptyFailureDomain.desiredInventory
      && throws malformedRealization.desiredInventory
      && throws malformedOwner.desiredInventory
      && throws foreignWiring.desiredInventory
      && throws foreignBinding.desiredInventory;
    projector-requirements =
      throws nativelessWiring.ownerProjections
      && throws uncredentialedRestic.ownerProjections
      && throws dualRepositoryRestic.ownerProjections;
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
