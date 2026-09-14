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

  publicTarget =
    target:
    if target == null then
      null
    else
      {
        inherit (target)
          targetId
          kind
          locator
          ownerData
          ;
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
          fixtureOnly
          ;
      };

  policyFor =
    declarations: state:
    let
      slot = declarations.slots.${state.slotId} or null;
      selectors = lib.unique state.selectorPolicies;
      policyId =
        if state.explicitPolicy != null then
          state.explicitPolicy
        else if selectors != [ ] then
          if builtins.length selectors == 1 then builtins.head selectors else null
        else if slot != null then
          slot.suggestedPolicy or null
        else
          null;
      policy = if policyId == null then null else declarations.policies.${policyId} or null;
      issues =
        lib.optional (slot == null) (
          mkIssue state.stateId null "missing-slot" "slot '${state.slotId}' is not declared"
        )
        ++ lib.optional (builtins.length selectors > 1 && state.explicitPolicy == null) (
          mkIssue state.stateId null "policy-conflict" (
            "equal-precedence selectors choose ${builtins.toJSON selectors}"
          )
        )
        ++ lib.optional (policyId == null && builtins.length selectors <= 1) (
          mkIssue state.stateId null "missing-policy" "no explicit, selector, or slot policy resolved"
        )
        ++ lib.optional (policyId != null && policy == null) (
          mkIssue state.stateId null "missing-policy" "policy '${policyId}' is not declared"
        )
        ++ lib.optional (policy != null && (policy.disposable or false) && (policy.routes or [ ]) != [ ]) (
          mkIssue state.stateId null "invalid-disposable-policy" (
            "disposable policy '${policyId}' declares routes"
          )
        );
    in
    {
      inherit
        slot
        policyId
        policy
        issues
        ;
    };

  firstIssueOr =
    strict: issues: value:
    if strict && issues != [ ] then throw (builtins.head issues).message else value;

  indexBy =
    field: values:
    lib.foldl' (
      indexed: value:
      let
        key = value.${field};
      in
      if indexed ? ${key} then
        throw "preserve: duplicate ${field} '${key}'"
      else
        indexed // { ${key} = value; }
    ) { } (builtins.attrValues values);

  coverageIssues =
    state: routeId: realization: target: integration: binding:
    let
      obligationId = "${state.stateId}::${routeId}";
      boundary = realization.boundary;
      source = if binding == null then { } else binding.source or { };
      includes = source.includes or [ ];
      exclusions = source.exclusions or [ ];
      childCovered =
        child:
        builtins.elem child includes || ((source.recursive or false) && !(builtins.elem child exclusions));
      missingChildren = builtins.filter (child: !(childCovered child)) boundary.requiredChildren;
      excludedRequired = builtins.filter (
        child: builtins.elem child exclusions
      ) boundary.requiredChildren;
    in
    lib.optional (!(integration.bindings ? ${obligationId})) (
      mkIssue state.stateId routeId "missing-binding" (
        "integration '${integration.integrationId}' has no binding for '${obligationId}'"
      )
    )
    ++ lib.optional (binding != null && (binding.targetId or null) != target.targetId) (
      mkIssue state.stateId routeId "target-mismatch" (
        "integration '${integration.integrationId}' binds a different target"
      )
    )
    ++ lib.optional (binding != null && (source.locator or null) != boundary.locator) (
      mkIssue state.stateId routeId "coverage-gap" (
        "owner source '${toString (source.locator or null)}' does not match '${boundary.locator}'"
      )
    )
    ++ lib.optional (binding != null && missingChildren != [ ]) (
      mkIssue state.stateId routeId "uncovered-child-boundary" (
        "owner source omits required children ${builtins.toJSON missingChildren}"
      )
    )
    ++ lib.optional (binding != null && excludedRequired != [ ]) (
      mkIssue state.stateId routeId "coverage-exclusion" (
        "owner source excludes required children ${builtins.toJSON excludedRequired}"
      )
    );

  routeAssessment =
    state: route: realization: target: integration:
    let
      obligationId = "${state.stateId}::${route.routeId}";
      binding = integration.bindings.${obligationId} or null;
      issues =
        lib.optional (!(builtins.elem route.operation integration.operations)) (
          mkIssue state.stateId route.routeId "unsupported-operation" (
            "integration '${integration.integrationId}' does not support '${route.operation}'"
          )
        )
        ++ lib.optional (!(builtins.elem realization.kind integration.realizationKinds)) (
          mkIssue state.stateId route.routeId "unsupported-realization" (
            "integration '${integration.integrationId}' does not support '${realization.kind}'"
          )
        )
        ++ lib.optional (!(builtins.elem target.kind integration.targetKinds)) (
          mkIssue state.stateId route.routeId "unsupported-target" (
            "integration '${integration.integrationId}' does not support '${target.kind}'"
          )
        )
        ++ coverageIssues state route.routeId realization target integration binding;
    in
    {
      inherit integration binding issues;
    };

  routeResolver =
    claim: ctx:
    let
      state = claim.subject;
      routeId = claim.routeId;
      obligationId = "${state.stateId}::${routeId}";
      route = ctx.declarations.routes.${routeId} or null;
      target = if route == null then null else route.target;
      candidates = builtins.attrValues ctx.declarations.integrations;
      assessments =
        if route == null || target == null then
          [ ]
        else
          map (routeAssessment state route claim.realization target) candidates;
      eligible = builtins.filter (assessment: assessment.issues == [ ]) assessments;
      selectedAssessment =
        if route == null || target == null || route.integration == null then
          null
        else
          routeAssessment state route claim.realization target route.integration;
      selected =
        if selectedAssessment != null && selectedAssessment.issues == [ ] then
          selectedAssessment
        else if selectedAssessment == null && builtins.length eligible == 1 then
          builtins.head eligible
        else
          null;
      ownerIssues =
        if route == null then
          [ ]
        else if target == null then
          [
            (mkIssue state.stateId routeId "unfulfilled-owner" "a target is required before owner selection")
          ]
        else if selectedAssessment != null then
          selectedAssessment.issues
        else if eligible == [ ] then
          lib.concatMap (assessment: assessment.issues) assessments
          ++ [
            (mkIssue state.stateId routeId "unfulfilled-owner" "no compatible lifecycle-owner integration")
          ]
        else if builtins.length eligible > 1 then
          [
            (mkIssue state.stateId routeId "ambiguous-owner" (
              "eligible integrations are ${builtins.toJSON (map (x: x.integration.integrationId) eligible)}"
            ))
          ]
        else
          [ ];
      issues =
        lib.optional (route == null) (
          mkIssue state.stateId routeId "missing-route" "route '${routeId}' is not declared"
        )
        ++ lib.optional (route != null && target == null) (
          mkIssue state.stateId routeId "missing-target" "route has no configured target"
        )
        ++ ownerIssues;
      value = {
        inherit obligationId routeId issues;
        stateId = state.stateId;
        routeIdentity = if route == null then null else route.id_hash;
        target = publicTarget target;
        integration = if selected == null then null else publicIntegration selected.integration;
        eligibleIntegrations = map (assessment: assessment.integration.integrationId) eligible;
        operation = if route == null then null else route.operation;
        requiredConsistency = if route == null then null else route.requiredConsistency;
        requiredFidelity = if route == null then null else route.requiredFidelity;
        realization = claim.realization;
        binding = if selected == null then null else selected.binding;
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

  realizationsFor =
    realizations: state:
    builtins.filter (
      contribution:
      builtins.isAttrs (contribution.state or null)
      && (contribution.state.id_hash or null) == state.id_hash
    ) realizations;

  stateResolver =
    claim: ctx:
    let
      state = claim.subject;
      resolvedPolicy = policyFor ctx.declarations state;
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
      routeIds =
        if resolvedPolicy.policy == null || issues != [ ] then [ ] else resolvedPolicy.policy.routes or [ ];
      realization = if realizationCount == 1 then (builtins.head contributions).realization else null;
      value = {
        inherit routeIds issues realization;
        inherit (state) stateId slotId mode;
        stateIdentity = state.id_hash;
        policyId = resolvedPolicy.policyId;
        caveats = if resolvedPolicy.slot == null then [ ] else resolvedPolicy.slot.caveats or [ ];
      };
    in
    firstIssueOr ctx.strict issues {
      resources.${state.stateId} = value;
      claims = map (
        routeId:
        engine.mkClaim {
          kind = "route-obligation";
          subject = state;
          inherit routeId realization;
        }
      ) routeIds;
    };

  kinds = engine.mkKinds [
    (engine.mkKind {
      name = "route-obligation";
      resolve = routeResolver;
    })
    (engine.mkKind {
      name = "state-protection";
      below = [ "route-obligation" ];
      resolve = stateResolver;
    })
  ];

  resolutionFor =
    declarations: realizations: strict: states:
    engine.resolveClaims {
      inherit kinds;
      ctx = { inherit declarations realizations strict; };
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
        routes = map (routeId: routeResources.${"${state.stateId}::${routeId}"}) state.routeIds;
      in
      removeAttrs state [ "routeIds" ]
      // {
        inherit routes;
        operational =
          state.mode == "enabled" && state.issues == [ ] && builtins.all (r: r.issues == [ ]) routes;
      }
    ) stateResources;

  sanitizeJobId =
    value:
    "preserve-"
    + builtins.concatStringsSep "" (
      map (character: if builtins.match "[A-Za-z0-9]" character != null then character else "-") (
        lib.stringToCharacters value
      )
    );

  projectOwners =
    executablePlan:
    let
      routes = lib.concatMap (state: state.routes) executablePlan.states;
      byOwner = owner: builtins.filter (route: route.integration.owner == owner) routes;
      zreplRoutes = byOwner "zrepl";
      resticRoutes = byOwner "nixos-restic";
    in
    {
      zrepl.services.zrepl = {
        enable = false;
        settings.jobs = map (
          route:
          let
            native = route.binding.native or { };
          in
          {
            name = sanitizeJobId route.obligationId;
            type = "push";
            filesystems.${route.realization.boundary.locator} = true;
            connect = native.connect or { };
            snapshotting = native.snapshotting or { };
            pruning = native.pruning or { };
          }
        ) zreplRoutes;
      };
      restic.services.restic.backups = builtins.listToAttrs (
        map (
          route:
          let
            native = route.binding.native or { };
          in
          {
            name = sanitizeJobId route.obligationId;
            value = {
              paths = native.paths or (lib.optional (route.realization.path != null) route.realization.path);
              exclude = native.exclude or (route.binding.source.exclusions or [ ]);
              repository = native.repository or route.target.locator;
              passwordFile = native.passwordFile or null;
              environmentFile = native.environmentFile or null;
              timerConfig = native.timerConfig or null;
              pruneOpts = native.pruneOpts or [ ];
              checkOpts = native.checkOpts or [ ];
              runCheck = native.runCheck or false;
              createWrapper = native.createWrapper or true;
            };
          }
        ) resticRoutes
      );
    };

  compile =
    {
      states ? config.den.preserve.states,
      slots ? config.den.preserve.slots,
      policies ? config.den.preserve.policies,
      routes ? config.den.preserve.routes,
      targets ? config.den.preserve.targets,
      integrations ? config.den.preserve.integrations,
      scratchDestinations ? config.den.preserve.scratchDestinations,
      realizations ? [ ],
    }:
    let
      routesById = indexBy "routeId" routes;
      knownStateHashes = map (state: state.id_hash) (builtins.attrValues states);
      invalidRealizations = builtins.filter (
        contribution:
        !builtins.isAttrs contribution
        || !builtins.isAttrs (contribution.state or null)
        || !(contribution.state ? id_hash)
        || !(builtins.elem contribution.state.id_hash knownStateHashes)
        || !builtins.isAttrs (contribution.realization or null)
        || !builtins.isAttrs (contribution.realization.boundary or null)
      ) realizations;
      validatedRealizations =
        if invalidRealizations == [ ] then
          realizations
        else
          throw "preserve: a realization contribution does not reference a declared state or valid boundary";
      declarations = {
        inherit
          states
          slots
          policies
          targets
          integrations
          scratchDestinations
          ;
        routes = routesById;
      };
      inventoryResolution = resolutionFor declarations validatedRealizations false states;
      enabledStates = lib.filterAttrs (_: state: state.mode == "enabled") states;
      executableResolution = resolutionFor declarations validatedRealizations true enabledStates;
      desiredInventory = {
        schemaVersion = 1;
        kind = "desired-inventory";
        states = documentsFor inventoryResolution;
        inherit scratchDestinations;
      };
      executablePlan = {
        schemaVersion = 1;
        kind = "executable-plan";
        states = documentsFor executableResolution;
        inherit scratchDestinations;
      };
    in
    {
      inherit desiredInventory executablePlan;
      resolutions = {
        inventory = inventoryResolution;
        executable = executableResolution;
      };
      ownerProjections = projectOwners executablePlan;
    };
in
{
  options.fleet.preserve = mkOption {
    type = types.raw;
    readOnly = true;
    description = "State-protection resolution and owner-projection interface.";
  };

  config.fleet.preserve = {
    inherit
      compile
      kinds
      projectOwners
      ;
  };
}
