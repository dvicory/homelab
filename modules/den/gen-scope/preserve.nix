{
  config,
  inputs,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  engine = inputs.gen-scope.lib;

  mkIssue = stateId: routeId: code: detail: {
    inherit stateId routeId code;
    message =
      "preserve: state '${stateId}'"
      + lib.optionalString (routeId != null) " route '${routeId}'"
      + ": ${code}: ${detail}";
  };

  forbiddenNativeKeys = [
    "source"
    "path"
    "paths"
    "target"
    "targetId"
  ];

  idHash = value: if builtins.isAttrs value then value.id_hash or null else null;

  uniqueById = builtins.foldl' (
    acc: value:
    if builtins.any (existing: idHash existing == idHash value) acc then acc else acc ++ [ value ]
  ) [ ];

  publicTarget =
    target:
    if target == null then
      null
    else
      {
        inherit (target) targetId failureDomain;
      };

  publicIntegration =
    integration:
    if integration == null then
      null
    else
      {
        inherit (integration)
          integrationId
          owner
          adapter
          protocolVersion
          timeoutSeconds
          maxResponseBytes
          fixtureOnly
          operations
          dataKinds
          requiredSourceCapabilities
          guaranteedConsistency
          fidelityGuarantees
          payloadRepresentation
          nativePointRepresentations
          realizationKindConstraints
          ;
      };

  # Satisfaction relation for semantic consistency guarantees. Exact matches
  # satisfy themselves; any guarantee satisfies `live`; filesystem,
  # application, and database guarantees may satisfy `crash`. No other
  # cross-level implication exists.
  consistencySatisfies =
    guarantee: required:
    required == "live"
    || guarantee == required
    || (
      required == "crash"
      && builtins.elem guarantee [
        "crash"
        "filesystem"
        "application"
        "database"
      ]
    );

  policyFor =
    state:
    let
      slot = state.slot;
      selectorIds = lib.unique (map (policy: policy.id_hash) state.selectorPolicies);
      selected =
        if state.explicitPolicy != null then
          state.explicitPolicy
        else if builtins.length selectorIds == 1 then
          builtins.head state.selectorPolicies
        else if selectorIds == [ ] then
          slot.suggestedPolicy
        else
          null;
      issues =
        lib.optional (builtins.length selectorIds > 1 && state.explicitPolicy == null) (
          mkIssue state.stateId null "policy-conflict" (
            "equal-precedence selectors choose ${
              builtins.toJSON (map (policy: policy.policyId) state.selectorPolicies)
            }"
          )
        )
        ++ lib.optional (selected == null && builtins.length selectorIds <= 1) (
          mkIssue state.stateId null "missing-policy" "no explicit, selector, or slot policy resolved"
        )
        ++ lib.optional (selected != null && selected.disposable && selected.routes != [ ]) (
          mkIssue state.stateId null "invalid-disposable-policy" (
            "disposable policy '${selected.policyId}' declares routes"
          )
        );
    in
    {
      inherit slot selected issues;
    };

  firstIssueOr =
    strict: issues: value:
    if strict && issues != [ ] then throw (builtins.head issues).message else value;

  realizationsFor =
    realizations: state:
    builtins.filter (
      contribution:
      builtins.isAttrs (contribution.state or null)
      && (contribution.state.id_hash or null) == state.id_hash
    ) realizations;

  obligationKey =
    state: route:
    "obligation:"
    + builtins.hashString "sha256" (
      builtins.toJSON {
        state = state.id_hash;
        route = route.id_hash;
      }
    );

  coverageFor =
    realization: source:
    let
      boundary = realization.boundary or { };
      exclusions = (boundary.exclusions or [ ]) ++ (source.exclude or [ ]);
      includes = source.include or [ ];
      childCovered =
        child:
        builtins.elem child includes
        || ((boundary.recursive or false) && !(builtins.elem child exclusions));
      required = boundary.requiredChildren or [ ];
    in
    {
      missingChildren = builtins.filter (child: !(childCovered child)) required;
      excludedRequired = builtins.filter (child: builtins.elem child exclusions) required;
    };

  assessmentFor =
    state: route: realization: integration:
    let
      slot = state.slot;
      missingCapabilities = builtins.filter (
        capability: !(builtins.elem capability (realization.capabilities or [ ]))
      ) integration.requiredSourceCapabilities;
      requiredFidelity = slot.requiredFidelity ++ route.requiredFidelity;
      missingFidelity = builtins.filter (
        fidelity: !(builtins.elem fidelity integration.fidelityGuarantees)
      ) requiredFidelity;
      acceptsDataKind =
        builtins.elem slot.dataKind integration.dataKinds || builtins.elem "*" integration.dataKinds;
      payloadOk =
        slot.acceptedPayloadFormats == [ ]
        || (
          integration.payloadRepresentation != null
          && builtins.elem integration.payloadRepresentation slot.acceptedPayloadFormats
        );
      consistencyOk =
        consistencySatisfies integration.guaranteedConsistency slot.requiredConsistency
        && (
          route.requiredConsistency == null
          || consistencySatisfies integration.guaranteedConsistency route.requiredConsistency
        );
      kindOk =
        integration.realizationKindConstraints == [ ]
        || builtins.elem (realization.kind or null) integration.realizationKindConstraints;
    in
    {
      inherit integration;
      issues =
        lib.optional (!(builtins.elem route.operation integration.operations)) (
          mkIssue state.stateId route.routeId "unsupported-operation" (
            "integration '${integration.integrationId}' does not support '${route.operation}'"
          )
        )
        ++ lib.optional (missingCapabilities != [ ]) (
          mkIssue state.stateId route.routeId "unsupported-capability" (
            "integration '${integration.integrationId}' requires missing source capabilities ${builtins.toJSON missingCapabilities}"
          )
        )
        ++ lib.optional (!kindOk) (
          mkIssue state.stateId route.routeId "unsupported-realization-kind" (
            "integration '${integration.integrationId}' requires kinds ${builtins.toJSON integration.realizationKindConstraints}"
          )
        )
        ++ lib.optional (!acceptsDataKind) (
          mkIssue state.stateId route.routeId "unsupported-data-kind" (
            "integration '${integration.integrationId}' does not accept data kind '${slot.dataKind}'"
          )
        )
        ++ lib.optional (!consistencyOk) (
          mkIssue state.stateId route.routeId "unsupported-consistency" (
            "integration '${integration.integrationId}' guarantees '${integration.guaranteedConsistency}'"
          )
        )
        ++ lib.optional (missingFidelity != [ ]) (
          mkIssue state.stateId route.routeId "unsupported-fidelity" (
            "integration '${integration.integrationId}' lacks fidelity ${builtins.toJSON missingFidelity}"
          )
        )
        ++ lib.optional (!payloadOk) (
          mkIssue state.stateId route.routeId "unsupported-payload-format" (
            "integration '${integration.integrationId}' produces payload representation ${builtins.toJSON integration.payloadRepresentation}, not one of ${builtins.toJSON slot.acceptedPayloadFormats}"
          )
        );
    };

  routeResolver =
    claim: ctx:
    let
      state = claim.subject;
      route = claim.route;
      routeId = route.routeId;
      target = route.target;
      obligationId = obligationKey state route;
      realization = claim.realization;

      matchingBindings = builtins.filter (
        binding:
        idHash (binding.state or null) == state.id_hash && idHash (binding.route or null) == route.id_hash
      ) ctx.declarations.bindings;
      binding = if builtins.length matchingBindings == 1 then builtins.head matchingBindings else null;
      bindingIssues =
        lib.optional (builtins.length matchingBindings > 1) (
          mkIssue state.stateId routeId "duplicate-binding" (
            "${toString (builtins.length matchingBindings)} bindings target this state and route"
          )
        )
        ++ lib.optional (binding != null && route.integration != null && binding.integration != null) (
          mkIssue state.stateId routeId "contradictory-binding" (
            "binding selects integration '${binding.integration.integrationId}' although the route fixes '${route.integration.integrationId}'"
          )
        )
        ++
          lib.optional
            (
              binding != null
              && builtins.any (key: builtins.hasAttr key (binding.nativeOverrides or { })) forbiddenNativeKeys
            )
            (
              mkIssue state.stateId routeId "contradictory-binding" (
                "binding native overrides repeat source or target keys"
              )
            );

      selectedIntegration =
        if route.integration != null then
          route.integration
        else if binding != null && binding.integration != null then
          binding.integration
        else
          null;

      candidates =
        if selectedIntegration != null then
          [ selectedIntegration ]
        else
          uniqueById (
            map (wiring: wiring.integration) (
              builtins.filter (
                wiring: target != null && idHash (wiring.target or null) == target.id_hash
              ) ctx.declarations.integrationTargets
            )
          );

      assessments =
        if target == null || realization == null then
          [ ]
        else
          map (assessmentFor state route realization) candidates;

      eligible = builtins.filter (assessment: assessment.issues == [ ]) assessments;
      selected =
        if selectedIntegration != null && assessments != [ ] then
          builtins.head assessments
        else if builtins.length eligible == 1 then
          builtins.head eligible
        else
          null;

      matchingWiring =
        if selected == null || target == null then
          [ ]
        else
          builtins.filter (
            wiring:
            idHash (wiring.integration or null) == selected.integration.id_hash
            && idHash (wiring.target or null) == target.id_hash
          ) ctx.declarations.integrationTargets;
      wiring = if builtins.length matchingWiring == 1 then builtins.head matchingWiring else null;
      wiringIssues =
        if selected == null || target == null then
          [ ]
        else
          lib.optional (matchingWiring == [ ]) (
            mkIssue state.stateId routeId "missing-integration-target" (
              "no Integration+Target wiring for '${selected.integration.integrationId}' and '${target.targetId}'"
            )
          )
          ++ lib.optional (builtins.length matchingWiring > 1) (
            mkIssue state.stateId routeId "duplicate-integration-target" (
              "${toString (builtins.length matchingWiring)} wirings repeat the selected Integration+Target pair"
            )
          )
          ++
            lib.optional
              (
                wiring != null
                && builtins.any (key: builtins.hasAttr key (wiring.native or { })) forbiddenNativeKeys
              )
              (
                mkIssue state.stateId routeId "contradictory-binding" (
                  "shared native configuration repeats source or target keys"
                )
              );

      source =
        if binding == null then
          {
            subpath = null;
            include = [ ];
            exclude = [ ];
          }
        else
          binding.source;
      coverage =
        if realization == null then
          {
            missingChildren = [ ];
            excludedRequired = [ ];
          }
        else
          coverageFor realization source;
      coverageIssues =
        lib.optional (realization != null && coverage.missingChildren != [ ]) (
          mkIssue state.stateId routeId "uncovered-child-boundary" (
            "source omits required children ${builtins.toJSON coverage.missingChildren}"
          )
        )
        ++ lib.optional (realization != null && coverage.excludedRequired != [ ]) (
          mkIssue state.stateId routeId "coverage-exclusion" (
            "source excludes required children ${builtins.toJSON coverage.excludedRequired}"
          )
        );

      weakConsistency =
        route.requiredConsistency != null
        && route.requiredConsistency != state.slot.requiredConsistency
        && consistencySatisfies state.slot.requiredConsistency route.requiredConsistency;
      weakIssues = lib.optional weakConsistency (
        mkIssue state.stateId routeId "weak-route-consistency" (
          "route requirement '${route.requiredConsistency}' weakens slot requirement '${state.slot.requiredConsistency}'"
        )
      );

      ownerIssues =
        if target == null then
          [
            (mkIssue state.stateId routeId "unfulfilled-owner" "a target is required before owner selection")
          ]
        else if realization == null then
          [ ]
        else if selectedIntegration != null && assessments != [ ] then
          (builtins.head assessments).issues
        else if eligible == [ ] then
          lib.concatMap (assessment: assessment.issues) assessments
          ++ [
            (mkIssue state.stateId routeId "unfulfilled-owner" "no compatible lifecycle-owner integration")
          ]
        else if builtins.length eligible > 1 then
          [
            (mkIssue state.stateId routeId "ambiguous-owner" (
              "eligible integrations are ${
                builtins.toJSON (map (assessment: assessment.integration.integrationId) eligible)
              }"
            ))
          ]
        else
          [ ];

      fixtureIssues =
        lib.optional (selected != null && (selected.integration.fixtureOnly or false) && !ctx.fixtureOnly)
          (
            mkIssue state.stateId routeId "fixture-only-integration" (
              "selected integration '${selected.integration.integrationId}' is fixture-only"
            )
          );

      issues =
        lib.optional (target == null) (
          mkIssue state.stateId routeId "missing-target" "route has no configured target"
        )
        ++ bindingIssues
        ++ wiringIssues
        ++ weakIssues
        ++ coverageIssues
        ++ fixtureIssues
        ++ ownerIssues;

      mergedNative = lib.recursiveUpdate (if wiring == null then { } else wiring.native or { }) (
        if binding == null then { } else binding.nativeOverrides or { }
      );

      value = {
        inherit obligationId routeId issues;
        stateId = state.stateId;
        routeIdentity = route.id_hash;
        target = publicTarget target;
        integration = if selected == null then null else publicIntegration selected.integration;
        eligibleIntegrations = map (assessment: assessment.integration.integrationId) eligible;
        operation = route.operation;
        semanticRequirements = {
          inherit (state.slot) dataKind requiredConsistency acceptedPayloadFormats;
          routeRequiredConsistency = route.requiredConsistency;
          requiredFidelity = lib.unique (state.slot.requiredFidelity ++ route.requiredFidelity);
        };
        guaranteedConsistency =
          if selected == null then null else selected.integration.guaranteedConsistency;
        payloadRepresentation =
          if selected == null then null else selected.integration.payloadRepresentation;
        nativePointRepresentations =
          if selected == null then [ ] else selected.integration.nativePointRepresentations;
        inherit realization;
        ownerConfig =
          if selected == null || wiring == null then
            null
          else
            {
              inherit source;
              native = mergedNative;
            };
        status =
          if builtins.any (issue: issue.code == "ambiguous-owner") issues then
            "ambiguous-owner"
          else if issues == [ ] then
            "resolved"
          else
            "unresolved";
      };
    in
    firstIssueOr ctx.strict issues {
      resources.${obligationId} = value;
      wiring.route = {
        inherit obligationId routeId;
        status = value.status;
      };
    };

  stateResolver =
    claim: ctx:
    let
      state = claim.subject;
      resolvedPolicy = policyFor state;
      contributions = realizationsFor ctx.realizations state;
      realizationCount = builtins.length contributions;
      realizationIssues =
        lib.optional (realizationCount == 0) (
          mkIssue state.stateId null "missing-realization" "no authoritative realization is declared"
        )
        ++ lib.optional (realizationCount > 1) (
          mkIssue state.stateId null "duplicate-realization" (
            "${toString realizationCount} authoritative realizations are declared"
          )
        );
      issues = resolvedPolicy.issues ++ realizationIssues;
      policyRoutes =
        if resolvedPolicy.selected == null || issues != [ ] then [ ] else resolvedPolicy.selected.routes;
      realization = if realizationCount == 1 then (builtins.head contributions).realization else null;
      value = {
        inherit issues realization;
        inherit (state) stateId mode;
        stateIdentity = state.id_hash;
        slotId = state.slot.slotId;
        policyId = if resolvedPolicy.selected == null then null else resolvedPolicy.selected.policyId;
        obligationKeys = map (route: obligationKey state route) policyRoutes;
      };
    in
    firstIssueOr ctx.strict issues {
      resources.${state.stateId} = value;
      claims = map (
        route:
        engine.mkClaim {
          kind = "route-obligation";
          subject = state;
          inherit route realization;
        }
      ) policyRoutes;
    };

  kinds = engine.mkKinds [
    (engine.mkKind {
      name = "state-protection";
      below = [ "route-obligation" ];
      resolve = stateResolver;
    })
    (engine.mkKind {
      name = "route-obligation";
      resolve = routeResolver;
    })
  ];

  resolutionFor =
    declarations: realizations: strict: fixtureOnly: states:
    engine.resolveClaims {
      inherit kinds;
      ctx = {
        inherit
          declarations
          realizations
          strict
          fixtureOnly
          ;
      };
      claims = map (
        state:
        engine.mkClaim {
          kind = "state-protection";
          subject = state;
        }
      ) (builtins.attrValues states);
    };

  documentsFor =
    resolution:
    let
      stateResources = resolution.resources."state-protection";
      routeResources = resolution.resources."route-obligation";
    in
    lib.mapAttrsToList (
      _name: state:
      let
        routes = map (key: routeResources.${key}) state.obligationKeys;
      in
      removeAttrs state [ "obligationKeys" ]
      // {
        inherit routes;
        operational =
          state.mode == "enabled" && state.issues == [ ] && builtins.all (route: route.issues == [ ]) routes;
      }
    ) stateResources;

  projectOwners =
    executablePlan: projectors:
    let
      resolved = lib.concatMap (
        state:
        builtins.filter (
          route: route.status == "resolved" && route.integration != null && route.ownerConfig != null
        ) state.routes
      ) executablePlan.states;
    in
    builtins.listToAttrs (
      map (
        route:
        let
          projector =
            projectors.${route.integration.integrationId}
              or (throw "preserve: no projector registered for integration '${route.integration.integrationId}'");
          jobId = "preserve-" + builtins.substring 0 16 (builtins.hashString "sha256" route.obligationId);
          projected = projector {
            inherit (route)
              obligationId
              stateId
              routeId
              target
              integration
              ownerConfig
              realization
              ;
            inherit jobId;
          };
        in
        {
          name = route.obligationId;
          value = {
            inherit (route) obligationId stateId routeId;
            inherit (projected) entryPoint config;
            targetId = route.target.targetId;
            integrationId = route.integration.integrationId;
          };
        }
      ) resolved
    );

  compile =
    {
      states ? config.den.preserve.states,
      slots ? config.den.preserve.slots,
      policies ? config.den.preserve.policies,
      routes ? config.den.preserve.routes,
      targets ? config.den.preserve.targets,
      integrations ? config.den.preserve.integrations,
      bindings ? config.den.preserve.bindings,
      integrationTargets ? config.den.preserve.integrationTargets,
      scratchDestinations ? config.den.preserve.scratchDestinations,
      realizations ? [ ],
      projectors ? config.fleet.preserve.projectors,
      fixtureOnly ? false,
    }:
    let
      knownStateHashes = map (state: state.id_hash) (builtins.attrValues states);
      knownRouteHashes = map (route: route.id_hash) (builtins.attrValues routes);
      knownTargetHashes = map (target: target.id_hash) (builtins.attrValues targets);
      knownIntegrationHashes = map (integration: integration.id_hash) (builtins.attrValues integrations);
      invalidTargets = builtins.filter (
        target: !(builtins.isAttrs (target.failureDomain or null)) || target.failureDomain == { }
      ) (builtins.attrValues targets);
      invalidRealizations = builtins.filter (
        contribution:
        !builtins.isAttrs contribution
        || !builtins.isAttrs (contribution.state or null)
        || !builtins.isString (contribution.state.id_hash or null)
        || !(builtins.elem contribution.state.id_hash knownStateHashes)
        || !builtins.isAttrs (contribution.realization or null)
        || !builtins.isAttrs (contribution.realization.owner or null)
        || !builtins.isString (contribution.realization.owner.kind or null)
        || !builtins.isString (contribution.realization.owner.id or null)
        || !builtins.isList (contribution.realization.capabilities or null)
        || !builtins.isAttrs (contribution.realization.boundary or null)
        || !builtins.isList (contribution.realization.access or null)
        || (
          let
            backing = contribution.realization.physicalBacking or null;
          in
          backing != null && !(builtins.isAttrs backing && !(backing ? authoritative))
        )
      ) realizations;
      invalidBindings = builtins.filter (
        binding:
        !builtins.isAttrs binding
        || !builtins.isString (idHash (binding.state or null))
        || !(builtins.elem (idHash (binding.state or null)) knownStateHashes)
        || !builtins.isString (idHash (binding.route or null))
        || !(builtins.elem (idHash (binding.route or null)) knownRouteHashes)
        || (
          binding.integration != null && !(builtins.elem (idHash binding.integration) knownIntegrationHashes)
        )
      ) bindings;
      invalidWiring = builtins.filter (
        wiring:
        !builtins.isAttrs wiring
        || !(builtins.elem (idHash (wiring.integration or null)) knownIntegrationHashes)
        || !(builtins.elem (idHash (wiring.target or null)) knownTargetHashes)
      ) integrationTargets;
      validated =
        if invalidTargets != [ ] then
          throw "preserve: a target must declare a non-empty failureDomain attribute set"
        else if invalidRealizations != [ ] then
          throw "preserve: a realization contribution does not reference a declared state or a valid boundary"
        else if invalidBindings != [ ] then
          throw "preserve: a binding does not reference declared state and route instances"
        else if invalidWiring != [ ] then
          throw "preserve: an Integration+Target wiring does not reference declared instances"
        else
          true;
      declarations = { inherit bindings integrationTargets; };
      inventoryResolution =
        assert validated;
        resolutionFor declarations realizations false fixtureOnly states;
      executableResolution =
        assert validated;
        resolutionFor declarations realizations true fixtureOnly (
          lib.filterAttrs (_name: state: state.mode == "enabled") states
        );
      desiredInventory = {
        schemaVersion = 1;
        kind = "desired-inventory";
        inherit scratchDestinations fixtureOnly;
        states = documentsFor inventoryResolution;
      };
      executablePlan = {
        schemaVersion = 1;
        kind = "executable-plan";
        inherit scratchDestinations fixtureOnly;
        states = documentsFor executableResolution;
      };
    in
    {
      inherit desiredInventory executablePlan;
      resolutions = {
        inventory = inventoryResolution;
        executable = executableResolution;
      };
      ownerProjections = projectOwners executablePlan projectors;
    };
in
{
  options.fleet.preserve = {
    compile = mkOption {
      type = types.raw;
      readOnly = true;
    };
    kinds = mkOption {
      type = types.raw;
      readOnly = true;
    };
    projectOwners = mkOption {
      type = types.raw;
      readOnly = true;
    };
    projectors = mkOption {
      type = types.attrsOf (types.functionTo types.raw);
      default = { };
      description = "Internal Integration-keyed owner projectors keyed by integrationId.";
    };
  };

  config.fleet.preserve = {
    inherit compile kinds projectOwners;
  };
}
