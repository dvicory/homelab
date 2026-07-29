# Policy rendering for the Gondolin secure-terminal backend (V3 §11).
#
# Nix is the authoring DSL: this file composes the hard safety floor,
# reviewed templates, bundles, and credential capabilities with a profile's
# selections and renders inert, versioned JSON. The broker validates and
# evaluates it; it never executes Nix or arbitrary predicates.
{ }:

let
  # Hard safety floor (§11.3): absolute ceilings and non-negotiable denials.
  # No layer may weaken these; the broker enforces them independently.
  floor = {
    maxResources = {
      cpus = 4;
      memoryMiB = 8192;
      diskMiB = 32768;
      pidsMax = 512;
      maxOutputBytes = 8388608; # 8 MiB per stream
      maxExecsPerVm = 64;
      maxCommandMs = 600000;
      ringBufferBytes = 262144;
    };
    maxVms = 8;
    maxVmStartsPerMinute = 12;
    maxFrameBytes = 1048576;
    maxInputBytes = 1048576;
  };

  # The Effect broker owns orphan reclamation. This is immutable policy,
  # rather than a caller-controlled ensure parameter, so a compromised
  # gateway cannot extend abandoned VM lifetime.
  environmentIdleTimeoutMs = 15 * 60 * 1000;

  # The Effect broker consumes these ceilings through authorization limits.
  # Keep them outside `floor`: the rollback broker validates the closed
  # policy object with an exact schema.
  workspaceHandoffLimitCeilings = {
    maxLogicalBytes = 67108864; # 64 MiB per frozen handoff
    maxEntries = 8192;
    maxFileBytes = 16777216; # 16 MiB per regular file
    maxPathBytes = 1024;
  };

  # Credential capabilities reference a network bundle, a logical secret id,
  # a reviewed adapter, bounded targets/actions, and an activation mode.
  # Secret VALUES never appear here — logical IDs only (§12.5).
  credentialCapabilities = {
    github-private-read = {
      networkBundle = "git-public";
      adapter = "github";
      secretRef = "hermes-terminal-github";
      targets = [ { owner = "daniel-vicory"; } ];
      actions = [ "git.fetch" ];
      activation = "approval";
      maximumGrantScope = "task";
    };
    github-push = {
      networkBundle = "git-public";
      adapter = "github";
      secretRef = "hermes-terminal-github";
      targets = [
        {
          owner = "daniel-vicory";
          repositories = [ "homelab-den" ];
        }
      ];
      actions = [ "git.push" ];
      activation = "approval";
      maximumGrantScope = "once";
    };
  };

  # Reviewed sandbox templates (§11.4). A template has at most one writable
  # workspace authority; moving to broader egress or different mounts
  # creates a new VM generation.
  templates = {
    project = {
      version = 1;
      asset = "general";
      network = {
        mode = "bundles";
        bundles = [
          "git-public"
          "npm-public"
          "pypi-public"
          "nix-cache-public"
        ];
      };
      workspace.type = "private";
      resources = {
        cpus = 2;
        memoryMiB = 4096;
      };
      envAllow = [ ];
      grantScopes = [
        "once"
        "task"
      ];
      credentials = [
        "github-private-read"
        "github-push"
      ];
      grantable = [ ];
    };
    research = {
      version = 1;
      asset = "general";
      network.mode = "public-anonymous";
      workspace.type = "private";
      resources = {
        cpus = 2;
        memoryMiB = 4096;
      };
      envAllow = [ ];
      grantScopes = [ ];
      credentials = [ ];
      grantable = [ ];
    };
    offline = {
      version = 1;
      asset = "minimal";
      network.mode = "deny-all";
      workspace.type = "private";
      resources = {
        cpus = 1;
        memoryMiB = 2048;
      };
      envAllow = [ ];
      grantScopes = [ ];
      credentials = [ ];
      grantable = [ ];
    };
    authenticated-action = {
      version = 1;
      asset = "minimal";
      network = {
        mode = "bundles";
        bundles = [ "git-public" ];
      };
      workspace.type = "private";
      resources = {
        cpus = 1;
        memoryMiB = 2048;
      };
      envAllow = [ ];
      grantScopes = [ "once" ];
      credentials = [
        "github-private-read"
        "github-push"
      ];
      grantable = [ ];
    };
  };

  # Render one profile's policy.json content (before policyId).
  mkPolicyDoc =
    {
      bundles,
      assets,
      profile,
      defaultTemplate,
      allowedPairs,
      maximum,
      worklanes ? { },
      ...
    }:
    {
      version = 1;
      inherit floor assets credentialCapabilities templates;
      inherit bundles;
      profiles.${profile} = {
        inherit defaultTemplate allowedPairs maximum worklanes;
      };
    };

  effectActions = [
    "environment.ensure"
    "environment.status"
    "environment.close"
    "exec.foreground"
    "fs.stat"
    "fs.list"
    "fs.read"
    "fs.write"
    "fs.mkdir"
    "fs.remove"
  ];

  mkEffectLane =
    {
      defaultTemplate,
      allowedPairs,
      maximum,
    }:
    let
      matchingPairs = builtins.filter (pair: pair.template == defaultTemplate) allowedPairs;
      pair =
        if matchingPairs == [ ] then
          throw "Gondolin Effect policy has no allowed asset pair for template '${defaultTemplate}'"
        else
          builtins.head matchingPairs;
      template =
        templates.${defaultTemplate}
          or (throw "Gondolin Effect policy references unknown template '${defaultTemplate}'");
      maximumResources = maximum.resources or { };
      min = left: right: if left < right then left else right;
      resourceLimit =
        name: hardDefault:
        min hardDefault (
          min (template.resources.${name} or hardDefault) (maximumResources.${name} or hardDefault)
        );
    in
    {
      asset = pair.asset;
      memoryMiB = resourceLimit "memoryMiB" floor.maxResources.memoryMiB;
      cpus = resourceLimit "cpus" floor.maxResources.cpus;
      workspaceGuestPath = "/workspace";
      limits = {
        maxCommandMs = floor.maxResources.maxCommandMs;
        maxOutputBytes = floor.maxResources.maxOutputBytes;
        maxInputBytes = floor.maxInputBytes;
        maxFileBytes = floor.maxInputBytes;
        maxListEntries = 4096;
        maxConcurrentExecs = 1;
      };
    };

in
{
  inherit floor templates credentialCapabilities workspaceHandoffLimitCeilings environmentIdleTimeoutMs;

  # Render policy.json with a content-derived policyId (§11: inert,
  # versioned JSON; the policy hash feeds VM generation identity).
  mkPolicy =
    { pkgs, profile, ... }@args:
    let
      doc = mkPolicyDoc args;
      policyId = builtins.hashString "sha256" (builtins.toJSON doc);
      rendered = doc // { inherit policyId; };
    in
    {
      json = pkgs.writeText "hermes-${profile}-sandbox-policy.json" (builtins.toJSON rendered);
      inherit policyId;
    };

  # Effect/HTTP compatibility envelope. Network authority is emitted as a
  # mandatory policy obligation per worklane; the broker must resolve and
  # enforce that obligation before creating a VM.
  mkEffectPolicy =
    {
      pkgs,
      profile,
      assets,
      bundles,
      defaultTemplate,
      allowedPairs,
      maximum,
      worklanes ? { },
      laneAuthorities ? { },
      workspaceHandoffEnabled ? false,
      workspaceHandoffLimits ? workspaceHandoffLimitCeilings,
      ...
    }:
    let
      supportedGrantScopes = [
        "once"
        "task"
        "conversation"
        "timed"
        "profile"
        "executor"
      ];
      supportedWorkspacePermissions = [
        "read-only"
        "workspace-write"
      ];
      invalidLaneAuthorityPermissions = builtins.filter (
        permission: !(builtins.elem permission supportedWorkspacePermissions)
      ) (map (authority: authority.maximumPermission or null) (builtins.attrValues laneAuthorities));
      validatedLaneAuthorities =
        if invalidLaneAuthorityPermissions == [ ] then
          laneAuthorities
        else
          throw "Gondolin Effect policy has invalid lane authority permissions";
      configuredGrantScopes = maximum.grantScopes or [ ];
      unknownGrantScopes = builtins.filter (
        scope: !(builtins.elem scope supportedGrantScopes)
      ) configuredGrantScopes;
      allowedGrantScopes =
        if unknownGrantScopes == [ ] then
          configuredGrantScopes
        else
          throw "Gondolin Effect policy has unknown grant scopes: ${builtins.concatStringsSep ", " unknownGrantScopes}";
      laneTemplateNames = {
        default = defaultTemplate;
      } // builtins.mapAttrs (_: lane: lane.defaultTemplate or defaultTemplate) worklanes;
      defaultLane = mkEffectLane {
        inherit defaultTemplate allowedPairs maximum;
      };
      laneMaximums = {
        default = maximum;
      } // builtins.mapAttrs (
        _: lane:
        let
          laneMaximum = lane.maximum or { };
        in
        maximum // laneMaximum // {
          resources = (maximum.resources or { }) // (laneMaximum.resources or { });
        }
      ) worklanes;
      mappedWorklanes = builtins.mapAttrs (
        laneName: lane:
        mkEffectLane {
          defaultTemplate = lane.defaultTemplate or defaultTemplate;
          allowedPairs = lane.allowedPairs or allowedPairs;
          maximum = laneMaximums.${laneName};
        }
      ) worklanes;
      lanes = {
        default = defaultLane;
      } // mappedWorklanes;
      networkPolicyId =
        laneName:
        let
          digest = builtins.hashString "sha256" (builtins.toJSON networkPoliciesByLane.${laneName});
        in
        "worklane:${laneName}:${builtins.substring 0 16 digest}";
      networkForLane =
        laneName:
        let
          network = templates.${laneTemplateNames.${laneName}}.network;
          permittedBundleNames = builtins.filter (
            bundleName: builtins.elem bundleName (laneMaximums.${laneName}.networkBundles or [ ])
          ) (network.bundles or [ ]);
        in
        {
          mode =
            if network.mode == "bundles" && permittedBundleNames == [ ] then
              "deny-all"
            else
              network.mode;
          destinations =
            if network.mode == "bundles" then
              builtins.concatLists (
                map (
                  bundleName:
                  ((bundles.${bundleName} or (throw "unknown network bundle '${bundleName}'")).destinations)
                ) permittedBundleNames
              )
            else
              [ ];
        };
      networkPoliciesByLane = builtins.mapAttrs (laneName: _: networkForLane laneName) lanes;
      networkPolicies = builtins.listToAttrs (
        map (laneName: {
          name = networkPolicyId laneName;
          value = networkPoliciesByLane.${laneName};
        }) (builtins.attrNames lanes)
      );
      limits = {
        cpus = floor.maxResources.cpus;
        memoryMiB = floor.maxResources.memoryMiB;
        maxCommandMs = floor.maxResources.maxCommandMs;
        maxOutputBytes = floor.maxResources.maxOutputBytes;
        maxInputBytes = floor.maxInputBytes;
        maxFileBytes = floor.maxInputBytes;
        maxListEntries = 4096;
        maxConcurrentExecs = 1;
        timeoutMs = floor.maxResources.maxCommandMs;
        outputBytes = floor.maxResources.maxOutputBytes;
        inputBytes = floor.maxInputBytes;
        bytes = floor.maxInputBytes;
        entries = 4096;
      };
      handoffLimit =
        name:
        let
          hardLimit = workspaceHandoffLimitCeilings.${name};
          configuredLimit = workspaceHandoffLimits.${name} or hardLimit;
        in
        if configuredLimit < hardLimit then configuredLimit else hardLimit;
      effectiveHandoffLimits =
        builtins.mapAttrs (name: _: handoffLimit name) workspaceHandoffLimitCeilings;
      policy = {
        version = 1;
        statements = [
          {
            effect = "allow";
            actions = builtins.filter (action: action != "environment.ensure") effectActions;
            resources = [ "environment:*" ];
            inherit limits;
          }
        ] ++ map (laneName: {
          effect = "allow";
          actions = [ "environment.ensure" ];
          resources = [ "worklane:${laneName}:environment:*" ];
          inherit limits;
          obligations = [
            {
              kind = "network";
              bundleId = networkPolicyId laneName;
            }
          ];
        }) (builtins.attrNames lanes)
        ++ (
          if workspaceHandoffEnabled then
            [
              {
                effect = "allow";
                actions = [
                  "workspace.capture"
                  "workspace.import"
                ];
                resources = [ "task-run:*" ];
                limits = effectiveHandoffLimits;
              }
              {
                effect = "allow";
                actions = [ "workspace.export" ];
                resources = [ "handoff:*" ];
                limits = effectiveHandoffLimits;
              }
            ]
          else
            [ ]
        );
      };
      grantPolicy = {
        allowedScopes = allowedGrantScopes;
        maxDurationSeconds = 3600;
        denialCooldownSeconds = 300;
        promptBudget = {
          maxNewRequests = 4;
          windowSeconds = 900;
        };
      };
      policyMaterial = {
        version = 1;
        inherit policy networkPolicies grantPolicy assets;
        laneAuthorities = validatedLaneAuthorities;
        defaultExecutor = "hermes-gateway";
        defaultAuthorityClass = "default";
        maxEnvironments = floor.maxVms;
        inherit environmentIdleTimeoutMs;
        worklanes = lanes;
      };
      # The full immutable Nix policy digest fences persisted environments,
      # requests, and grants. Identical rebuilds retain the same identity.
      policyDigest = builtins.hashString "sha256" (builtins.toJSON policyMaterial);
      doc = policyMaterial // { inherit policyDigest; };
      policyId = builtins.hashString "sha256" (builtins.toJSON doc);
    in
    {
      json = pkgs.writeText "hermes-${profile}-effect-sandbox-policy.json" (builtins.toJSON doc);
      inherit policyId;
    };
}
