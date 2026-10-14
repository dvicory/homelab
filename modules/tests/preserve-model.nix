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
      operations = [
        "describe"
        "status"
        "points"
        "run"
      ];
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
          tags = [ "shared" ];
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

  coverageFixture =
    mode: spec:
    compile
      (singleRoute {
        states.application.mode = mode;
        policies.protected.routes = [ "route-restic" ];
        projectors = spec.projectors or config.fleet.preserve.projectors;
        bindings = [
          {
            state = "application";
            route = "route-restic";
            source = emptySource // (spec.source or { });
          }
        ];
      })
      [
        {
          state = "application";
          realization = coveredRealization // {
            kind = spec.kind or coveredRealization.kind;
            path = spec.path or coveredRealization.path;
            boundary = coveredRealization.boundary // (spec.boundary or { });
          };
        }
      ];
  narrowedCoverageGap = {
    source.subpath = "db";
  };
  missingCoverage = map (coverageFixture "enabled") [
    narrowedCoverageGap
    { source.subpath = "database/records"; }
    { source.subpath = "database-other"; }
    { boundary.recursive = false; }
    {
      path = "/";
      boundary = {
        recursive = false;
        requiredChildren = [ "/database" ];
      };
    }
    {
      boundary = {
        recursive = false;
        requiredChildren = [ "/srv/app/database/records" ];
      };
      source.subpath = "database";
    }
    {
      boundary = {
        recursive = false;
        requiredChildren = [ "/srv/app/database/records" ];
      };
      source = {
        subpath = "db";
        include = [ "/srv/app/database" ];
      };
    }
    {
      source = {
        subpath = "db";
        include = [ "/srv/app/database-other" ];
      };
    }
    {
      source = {
        subpath = "db";
        include = [ "/srv/app/database/records" ];
      };
    }
  ];
  validCoverage = map (coverageFixture "enabled") [
    { }
    {
      boundary = {
        recursive = false;
        requiredChildren = [ "/srv/app/db" ];
      };
      source.subpath = "db";
    }
    {
      path = "/";
      boundary.requiredChildren = [ "/database" ];
    }
    {
      boundary.recursive = false;
      source.subpath = "database";
    }
    {
      boundary.requiredChildren = [ "/srv/app/database/records" ];
      source.subpath = "database";
    }
    {
      boundary.recursive = false;
      source = {
        subpath = "db";
        include = [ "/srv/app/database" ];
      };
    }
    {
      boundary.requiredChildren = [ "/srv/app/database/records" ];
      source = {
        subpath = "db";
        include = [ "/srv/app/database" ];
      };
    }
    { source.exclude = [ "/srv/app/database-other" ]; }
    {
      boundary.exclusions = [ "/srv/app/db" ];
      source.subpath = "database";
    }
    {
      path = "/";
      boundary = {
        recursive = false;
        requiredChildren = [ "/database" ];
      };
      source = {
        subpath = "db";
        include = [ "/database" ];
      };
    }
  ];
  excludedCoverage = map (coverageFixture "enabled") (
    map (path: { source.exclude = [ path ]; }) [
      "/srv/app/database"
      "/srv/app"
      "/srv"
      "/"
      "/srv/app/database/records"
    ]
    ++ [
      {
        boundary.recursive = false;
        source = {
          subpath = "db";
          include = [ "/srv/app/database" ];
          exclude = [ "/srv/app" ];
        };
      }
      { boundary.exclusions = [ "/srv/app" ]; }
      { boundary.exclusions = [ "/srv/app/database/records" ]; }
    ]
  );
  planOnlyCoverageGap = coverageFixture "plan-only" narrowedCoverageGap;

  nonCanonicalBoundaryCoverage = map (coverageFixture "enabled") [
    {
      boundary.requiredChildren = [ "/srv/app/db/../database" ];
      source.subpath = "db";
    }
    { boundary.requiredChildren = [ "/srv/app/./database" ]; }
    { boundary.requiredChildren = [ "/srv//app/database" ]; }
    { boundary.requiredChildren = [ "/srv/app/database/" ]; }
    { boundary.exclusions = [ "/srv/app/db/../database" ]; }
    { boundary.exclusions = [ "/srv/app/./database" ]; }
    { boundary.exclusions = [ "/srv//app/database" ]; }
    { boundary.exclusions = [ "/srv/app/database/" ]; }
    { path = "/srv/app/db/../database"; }
    { path = "/srv/./app"; }
    { path = "/srv//app"; }
    { path = "/srv/app/"; }
    {
      kind = "filesystem";
      path = null;
    }
    {
      kind = "host-filesystem";
      path = null;
    }
  ];
  nonCanonicalSourceCoverage =
    mode:
    map
      (
        source:
        coverageFixture mode {
          inherit source;
          # Coverage admission must not rely on a registered owner's renderer.
          projectors = { };
        }
      )
      [
        { exclude = [ "/srv/app/db/../database" ]; }
        { exclude = [ "/srv/app/./database" ]; }
        { exclude = [ "/srv//app/database" ]; }
        { exclude = [ "/srv/app/database/" ]; }
        { include = [ "/srv/app/db/../database" ]; }
        { include = [ "/srv/app/./database" ]; }
        { subpath = "database/../db"; }
        { subpath = "database/./records"; }
      ];

  unsupportedOperation = compile (singleRoute {
    routes.route-zrepl.operation = "restore";
  }) [ realizationSpec ];

  missingBaseline = compile (singleRoute {
    integrations.zrepl.operations = [ "run" ];
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
        nativeOverrides.restic.tags = [
          "edge"
          "edge node's"
        ];
      }
    ];
  }) [ realizationSpec ];

  invalidResticSources = [
    { subpath = "../escape"; }
    { subpath = "db/../../escape"; }
    { subpath = "/etc"; }
    { subpath = ""; }
    { subpath = "."; }
    { subpath = "db/./child"; }
    { subpath = "db//child"; }
    { subpath = "db/"; }
    { include = [ "/etc/shadow" ]; }
    { include = [ "/srv/application/extra" ]; }
    { include = [ "/srv/app/../escape" ]; }
    { include = [ "/srv/app-other/extra" ]; }
    { include = [ "extra" ]; }
  ];
  invalidLocatorRealizations = [
    (builtins.removeAttrs zfsRealization [ "locator" ])
  ]
  ++ map (locator: zfsRealization // { inherit locator; }) [
    null
    42
    ""
    { }
  ];
  invalidLocatorResults =
    mode:
    map (
      realization:
      compile (singleRoute { states.application.mode = mode; }) [
        {
          state = "application";
          inherit realization;
        }
      ]
    ) invalidLocatorRealizations;

  rootRestic =
    compile
      (singleRoute {
        policies.protected.routes = [ "route-restic" ];
        bindings = [
          {
            state = "application";
            route = "route-restic";
            source = emptySource // {
              subpath = "db";
              include = [ "/extra" ];
            };
          }
        ];
      })
      [
        {
          state = "application";
          realization = zfsRealization // {
            path = "/";
          };
        }
      ];

  conflictingZreplNative = [
    { name = "redirected-job"; }
    { type = "sink"; }
    { filesystems."unrelated/dataset" = true; }
  ];
  rejectedProjectionDeclarations =
    map
      (
        native:
        singleRoute {
          bindings = [
            {
              state = "application";
              route = "route-zrepl";
              nativeOverrides.zrepl = native;
            }
          ];
        }
      )
      (
        conflictingZreplNative
        ++ [
          { connect.listener_name = "diverged-sink"; }
          { snapshotting.interval = "10h"; }
          { pruning.keep_sender = [ ]; }
          { send.encrypted = true; }
          { replication.concurrency.steps = 2; }
          { conflict_resolution.initial_replication = "all"; }
        ]
      )
    ++ map (
      native:
      singleRoute {
        integrationTargets = map (
          wiring:
          if wiring.integration == "zrepl" then
            lib.recursiveUpdate wiring { native.zrepl = native; }
          else
            wiring
        ) common.integrationTargets;
      }
    ) conflictingZreplNative
    ++
      map
        (
          source:
          singleRoute {
            bindings = [
              {
                state = "application";
                route = "route-zrepl";
                source = emptySource // source;
              }
            ];
          }
        )
        [
          { subpath = "db"; }
          { include = [ "/srv/app/extra" ]; }
          { exclude = [ "/srv/app/tmp" ]; }
        ]
    ++
      map
        (
          tags:
          singleRoute {
            policies.protected.routes = [ "route-restic" ];
            bindings = [
              {
                state = "application";
                route = "route-restic";
                nativeOverrides.restic.tags = tags;
              }
            ];
          }
        )
        [
          "not-a-list"
          [ 1 ]
          [ "" ]
        ]
    ++
      map
        (
          native:
          singleRoute {
            policies.protected.routes = [ "route-restic" ];
            bindings = [
              {
                state = "application";
                route = "route-restic";
                nativeOverrides.restic = native;
              }
            ];
          }
        )
        [
          { target.repository = "/archive/diverged"; }
          { target.repositoryFile = "/run/credentials/other-repository"; }
          { target.passwordFile = "/run/credentials/other-password"; }
          { target.environmentFile = "/run/credentials/other-environment"; }
          { timerConfig.OnCalendar = "daily"; }
          { pruneOpts = [ "--keep-last 1" ]; }
          { checkOpts = [ "--read-data" ]; }
          { runCheck = false; }
          { createWrapper = false; }
        ]
    ++ map (
      source:
      singleRoute {
        policies.protected.routes = [ "route-restic" ];
        bindings = [
          {
            state = "application";
            route = "route-restic";
            source = emptySource // source;
          }
        ];
      }
    ) invalidResticSources;
  rejectedProjections = map (
    declarations: compile declarations [ realizationSpec ]
  ) rejectedProjectionDeclarations;
  planOnlyRejectedProjections = map (
    declarations:
    compile (lib.recursiveUpdate declarations {
      states.application.mode = "plan-only";
    }) [ realizationSpec ]
  ) rejectedProjectionDeclarations;

  externalAdapter = compile (singleRoute {
    integrations.zrepl.integrationId = "external-owner";
  }) [ realizationSpec ];
  unusableRegisteredProjector = compile (singleRoute {
    projectors.zrepl = _args: throw "fixture: unusable registered projector";
  }) [ realizationSpec ];

  fencedExternalDeclarations = singleRoute {
    integrations.zrepl = {
      integrationId = "external-owner";
      operations = [
        "describe"
        "status"
        "points"
        "run"
        "restore"
      ];
    };
    integrationTargets = map (
      wiring:
      if wiring.integration == "zrepl" then
        wiring
        // {
          targetBoundaries = {
            paths = [ "/archive/external" ];
            nativeLocators = [ "fixture-backup/external" ];
            nativeNamespace = "fixture-zfs";
          };
        }
      else
        wiring
    ) common.integrationTargets;
  };
  fencedExternal = compile fencedExternalDeclarations [ realizationSpec ];
  missingExternalFencesDeclarations = fencedExternalDeclarations // {
    integrationTargets = map (
      wiring: builtins.removeAttrs wiring [ "targetBoundaries" ]
    ) fencedExternalDeclarations.integrationTargets;
  };
  missingExternalFences = compile missingExternalFencesDeclarations [ realizationSpec ];
  plannedMissingExternalFences = compile (lib.recursiveUpdate missingExternalFencesDeclarations {
    states.application.mode = "plan-only";
  }) [ realizationSpec ];
  invalidExternalFences = compile (
    fencedExternalDeclarations
    // {
      integrationTargets = map (
        wiring:
        if wiring.integration == "zrepl" then
          lib.recursiveUpdate wiring {
            targetBoundaries.paths = [ "relative/target" ];
          }
        else
          wiring
      ) fencedExternalDeclarations.integrationTargets;
    }
  ) [ realizationSpec ];
  resticBoundaryFor =
    repository:
    let
      result = compile (singleRoute {
        policies.protected.routes = [ "route-restic" ];
        integrationTargets = map (
          wiring:
          if wiring.integration == "restic" then
            lib.recursiveUpdate wiring {
              native.restic.target.repository = repository;
            }
          else
            wiring
        ) common.integrationTargets;
      }) [ realizationSpec ];
    in
    (builtins.head (builtins.head result.executablePlan.states).routes).targetBoundaries;

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
  mixedModes =
    compile
      (lib.recursiveUpdate common {
        states.planned = state // {
          stateId = "application/planned";
          mode = "plan-only";
        };
      })
      [
        realizationSpec
        (realizationSpec // { state = "planned"; })
      ];

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

  # Synthetic capability/access examples, not observations of the deployed fleet.
  # Host-backed runtime views keep the host's single authoritative realization.
  platformSpecs = [
    {
      state = "container";
      realization = zfsRealization // {
        access = [
          {
            kind = "container";
            name = "fixture-application";
            path = "/data";
          }
        ];
      };
    }
    {
      state = "incus";
      realization = zfsRealization // {
        access = [
          {
            kind = "incus";
            instance = "fixture-database";
            device = "data";
            path = "/srv/data";
            uidMapping = {
              guest = 1000;
              host = 1001000;
            };
            gidMapping = {
              guest = 1000;
              host = 1001000;
            };
          }
        ];
      };
    }
    {
      state = "kube-pv";
      realization = zfsRealization // {
        access = [
          {
            kind = "kubernetes-local-pv";
            hostPath = "/srv/app";
            claim = "fixture-data";
          }
          {
            kind = "kubernetes-host-path";
            hostPath = "/srv/app";
          }
        ];
      };
    }
    {
      state = "kube-pvc";
      realization = zfsRealization // {
        kind = "csi-pvc";
        owner = {
          kind = "kubernetes";
          id = "fixture-cluster";
        };
        locator = "fixture-namespace/fixture-data";
        path = null;
        capabilities = [ "filesystem-read" ];
        access = [
          {
            kind = "kubernetes-pvc";
            claim = "fixture-data";
          }
        ];
      };
    }
    {
      state = "microvm";
      realization = zfsRealization // {
        access = [
          {
            kind = "microvm";
            share = "fixture-state";
            path = "/srv/state";
          }
        ];
      };
    }
    {
      state = "microvm-volume";
      realization = zfsRealization // {
        kind = "microvm-native-volume";
        owner = {
          kind = "microvm";
          id = "fixture-vm";
        };
        locator = "fixture-volume";
        path = "/fixture/volume";
        capabilities = [ "filesystem-read" ];
        access = [
          {
            kind = "microvm";
            volume = "fixture-volume";
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

  moduleFixture = {
    system.stateVersion = "26.05";
  };
  zreplModule = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      zreplProjection.config
      moduleFixture
    ];
  };
  resticModule = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      resticProjection.config
      moduleFixture
    ];
  };
  zreplModuleJob = builtins.head zreplModule.config.services.zrepl.settings.jobs;
  resticModuleBackups = resticModule.config.services.restic.backups;
  resticModuleJob = resticModuleBackups.${builtins.head (builtins.attrNames resticModuleBackups)};

  narrowedProjections = narrowed.ownerProjections;
  narrowedProjection = narrowedProjections.${narrowedRoute.obligationId};
  narrowedBackups = narrowedProjection.config.services.restic.backups;
  narrowedJob = narrowedBackups.${builtins.head (builtins.attrNames narrowedBackups)};
  narrowedModule = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      narrowedProjection.config
      moduleFixture
    ];
  };
  narrowedModuleBackups = narrowedModule.config.services.restic.backups;
  narrowedModuleJob =
    narrowedModuleBackups.${builtins.head (builtins.attrNames narrowedModuleBackups)};

  misleadingOwner = compile (lib.recursiveUpdate common {
    integrations.zrepl.owner = "restic";
  }) [ realizationSpec ];
  misleadingZreplRoute = routeById (builtins.head misleadingOwner.desiredInventory.states).routes "route-zrepl";
  misleadingProjection = misleadingOwner.ownerProjections.${misleadingZreplRoute.obligationId};

  platformStates = stateById platforms.desiredInventory;
  postgresEntry = (builtins.head postgres.desiredInventory.states);

  assertions = {
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
    plan-only-authoritative-fences =
      builtins.length planOnlyIncomplete.executablePlan.protectedRealizations == 1
      &&
        (builtins.head planOnlyIncomplete.executablePlan.protectedRealizations).stateId
        == (builtins.head planOnlyIncomplete.desiredInventory.states).stateId
      &&
        (builtins.head planOnlyIncomplete.executablePlan.protectedRealizations).realization
        == realizationSpec.realization
      && builtins.length duplicateRealization.desiredInventory.protectedRealizations == 2;
    mixed-modes-fence-without-enabling =
      builtins.length mixedModes.executablePlan.states == 1
      && builtins.length mixedModes.executablePlan.protectedRealizations == 2
      && builtins.any (
        protected: protected.stateId == "application/planned"
      ) mixedModes.executablePlan.protectedRealizations
      && builtins.all (entry: entry.mode == "enabled") mixedModes.executablePlan.states;
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
    narrowed-coverage-gaps = builtins.all (
      result:
      hasIssue "uncovered-child-boundary" result
      && allIssueContext result
      && !(builtins.head result.desiredInventory.states).operational
      && throws result.executablePlan
    ) missingCoverage;
    canonical-realization-boundaries = builtins.all (
      result: throws result.desiredInventory && throws result.executablePlan
    ) nonCanonicalBoundaryCoverage;
    canonical-source-coverage = builtins.all (
      result:
      hasIssue "invalid-source-selection" result
      && allIssueContext result
      && !(builtins.head result.desiredInventory.states).operational
      && throws result.executablePlan
    ) (nonCanonicalSourceCoverage "enabled");
    plan-only-canonical-source-coverage = builtins.all (
      result:
      hasIssue "invalid-source-selection" result
      && builtins.isString (builtins.toJSON result.desiredInventory)
      && !(builtins.head result.desiredInventory.states).operational
      && result.executablePlan.states == [ ]
    ) (nonCanonicalSourceCoverage "plan-only");
    valid-narrowed-coverage = builtins.all (
      result:
      (builtins.head result.executablePlan.states).operational
      && (builtins.head (builtins.head result.desiredInventory.states).routes).status == "resolved"
    ) validCoverage;
    coverage-exclusion-boundaries = builtins.all (
      result:
      hasIssue "coverage-exclusion" result
      && hasIssue "uncovered-child-boundary" result
      && throws result.executablePlan
    ) excludedCoverage;
    plan-only-coverage-gap =
      hasIssue "uncovered-child-boundary" planOnlyCoverageGap
      && allIssueContext planOnlyCoverageGap
      && builtins.isString (builtins.toJSON planOnlyCoverageGap.desiredInventory)
      && !(builtins.head planOnlyCoverageGap.desiredInventory.states).operational
      &&
        (builtins.head (builtins.head planOnlyCoverageGap.desiredInventory.states).routes).status
        == "unresolved"
      && planOnlyCoverageGap.executablePlan.states == [ ];
    capability-matrix =
      hasIssue "unsupported-operation" unsupportedOperation
      && hasIssue "unsupported-baseline-operation" missingBaseline
      && throws missingBaseline.executablePlan
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
      &&
        narrowedRoute.ownerConfig.native.restic.tags == [
          "edge"
          "edge node's"
        ]
      &&
        narrowedJob.paths == [
          "/srv/app/db"
          "/srv/app/extra"
        ]
      && narrowedJob.exclude == [ "/srv/app/tmp" ]
      && narrowedJob.repository == "/archive/application"
      &&
        narrowedJob.extraBackupArgs == [
          "--tag edge"
          "--tag 'edge node'\\''s'"
        ];
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
      platforms.desiredInventory.fixtureOnly
      && builtins.length platforms.desiredInventory.states == 6
      && builtins.all (
        entry: entry.realization != null && builtins.isList entry.realization.access
      ) platforms.desiredInventory.states
      &&
        builtins.all
          (
            name:
            let
              realization = platformStates."platform/${name}".realization;
            in
            realization.kind == "zfs-dataset"
            && realization.owner == zfsRealization.owner
            && realization.locator == zfsRealization.locator
            && realization.path == zfsRealization.path
          )
          [
            "container"
            "incus"
            "kube-pv"
            "microvm"
          ]
      && builtins.length platformStates."platform/kube-pv".realization.access == 2
      && builtins.length platformStates."platform/microvm".realization.access == 1
      &&
        (builtins.head platformStates."platform/incus".realization.access).uidMapping == {
          guest = 1000;
          host = 1001000;
        }
      &&
        (builtins.head platformStates."platform/incus".realization.access).gidMapping == {
          guest = 1000;
          host = 1001000;
        }
      && platformStates."platform/kube-pvc".realization.owner.kind == "kubernetes"
      && platformStates."platform/kube-pvc".realization.capabilities == [ "filesystem-read" ]
      && platformStates."platform/microvm-volume".realization.owner.kind == "microvm"
      && platformStates."platform/microvm-volume".realization.capabilities == [ "filesystem-read" ];
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
      &&
        zreplJob.name
        == "preserve-" + builtins.substring 0 16 (builtins.hashString "sha256" zreplRoute.obligationId)
      && zreplProjection.config.services.zrepl.enable == false
      && zreplJob.type == "push"
      && zreplJob.filesystems == { "source/app" = true; }
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
      && resticJob.extraBackupArgs == [ "--tag shared" ]
      && builtins.all (key: !(builtins.elem key (builtins.attrNames zreplJob))) [
        "capture"
        "protect"
        "release"
        "retry"
      ];
    module-schema-evaluations =
      zreplModule.config.services.zrepl.enable == false
      && zreplModuleJob.name == zreplJob.name
      && zreplModuleJob.type == "push"
      && zreplModuleJob.filesystems == { "source/app" = true; }
      && zreplModuleJob.connect.listener_name == "fixture-sink"
      && zreplModuleJob.snapshotting.interval == "1h"
      && (builtins.head zreplModuleJob.pruning.keep_sender).count == 12
      && resticModuleJob.paths == [ "/srv/app" ]
      && resticModuleJob.repository == "/archive/application"
      && resticModuleJob.passwordFile == "/run/credentials/restic-password"
      && resticModuleJob.timerConfig.OnCalendar == "hourly"
      && resticModuleJob.pruneOpts == [ "--keep-daily 7" ]
      && resticModuleJob.runCheck
      && resticModuleJob.extraBackupArgs == [ "--tag shared" ]
      && (resticModule.options.services.restic.backups.type.getSubOptions [ ]) ? extraBackupArgs
      && narrowedModuleJob.paths == narrowedJob.paths
      && narrowedModuleJob.exclude == narrowedJob.exclude
      &&
        narrowedModuleJob.extraBackupArgs == [
          "--tag edge"
          "--tag 'edge node'\\''s'"
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
      builtins.all
        (
          result:
          (hasIssue "invalid-owner-projection" result || hasIssue "invalid-source-selection" result)
          && (builtins.head result.desiredInventory.states).operational == false
          && throws result.executablePlan
        )
        (
          rejectedProjections
          ++ invalidLocatorResults "enabled"
          ++ [
            nativelessWiring
            uncredentialedRestic
            dualRepositoryRestic
            unusableRegisteredProjector
          ]
        );
    plan-only-projector-diagnostics = builtins.all (
      result:
      (hasIssue "invalid-owner-projection" result || hasIssue "invalid-source-selection" result)
      && builtins.isString (builtins.toJSON result.desiredInventory)
      && (builtins.head result.desiredInventory.states).operational == false
      && result.executablePlan.states == [ ]
      && result.ownerProjections == { }
    ) (planOnlyRejectedProjections ++ invalidLocatorResults "plan-only");
    root-realization-narrowing =
      let
        route = builtins.head (builtins.head rootRestic.executablePlan.states).routes;
        backups = rootRestic.ownerProjections.${route.obligationId}.config.services.restic.backups;
        job = backups.${builtins.head (builtins.attrNames backups)};
      in
      route.status == "resolved"
      &&
        job.paths == [
          "/db"
          "/extra"
        ];
    external-adapter-without-projector =
      (builtins.head externalAdapter.executablePlan.states).operational
      &&
        (builtins.head (builtins.head externalAdapter.executablePlan.states).routes)
        .integration.integrationId == "external-owner"
      && externalAdapter.ownerProjections == { };
    owner-emitted-retained-fences =
      (builtins.head (builtins.head fencedExternal.executablePlan.states).routes).targetBoundaries == {
        paths = [ "/archive/external" ];
        nativeLocators = [ "fixture-backup/external" ];
        nativeNamespace = "fixture-zfs";
      }
      && fencedExternal.ownerProjections == { }
      && hasIssue "missing-target-boundaries" missingExternalFences
      && throws missingExternalFences.executablePlan
      && hasIssue "invalid-target-boundaries" invalidExternalFences
      && throws invalidExternalFences.executablePlan
      && hasIssue "missing-target-boundaries" plannedMissingExternalFences
      && builtins.isString (builtins.toJSON plannedMissingExternalFences.desiredInventory)
      && plannedMissingExternalFences.executablePlan.states == [ ];
    restic-native-destination-fences =
      let
        remote = resticBoundaryFor "sftp:fixture:/archive/remote";
      in
      resticRoute.targetBoundaries.paths == [ "/archive/application" ]
      && (resticBoundaryFor "local:/archive/local").paths == [ "/archive/local" ]
      && remote.paths == [ ]
      && remote.nativeLocators == [ "sftp:fixture:/archive/remote" ]
      && remote.nativeNamespace == "restic.repository"
      && resticBoundaryFor "relative/repository" == null;
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
