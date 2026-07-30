{ lib }:
let
  inherit (lib) mkOption types;

  nullableString = types.nullOr types.str;
  positiveInteger = types.ints.positive;

  agentType = types.submodule {
    options = {
      model = mkOption {
        type = nullableString;
        default = null;
        description = "Fixed model selected for this worker lane.";
      };
      reasoningEffort = mkOption {
        type = types.nullOr (
          types.enum [
            "low"
            "medium"
            "high"
          ]
        );
        default = null;
        description = "Fixed reasoning effort selected for this worker lane.";
      };
      role = mkOption {
        type = nullableString;
        default = null;
        description = "Trusted worker-role prompt overlay.";
      };
      soul = mkOption {
        type = types.nullOr (types.either types.path types.str);
        default = null;
        description = "Trusted SOUL file or store path for this worker lane.";
      };
      tools = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Model-visible tools exposed to this worker lane.";
      };
      toolsets = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Model-visible toolsets exposed to this worker lane.";
      };
      skills = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Skills exposed to this worker lane.";
      };
    };
  };

  workspaceType = types.submodule {
    options = {
      projectMode = mkOption {
        type = types.enum [
          "none"
          "optional"
          "required"
        ];
        default = "none";
        description = "Whether tasks may or must select a managed Project.";
      };
      scratchProvider = mkOption {
        type = types.enum [ "broker-scratch" ];
        default = "broker-scratch";
        description = "Trusted workspace provider used for non-Project tasks.";
      };
      projectProvider = mkOption {
        type = types.nullOr (types.enum [ "broker-project" ]);
        default = null;
        description = "Trusted workspace provider used for Project tasks.";
      };
      maximumPermission = mkOption {
        type = types.enum [
          "none"
          "read-only"
          "workspace-write"
        ];
        default = "none";
        description = "Maximum direct Project permission this lane can receive.";
      };
      supportedSourceKinds = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Project source kinds supported by the selected provider contract.";
      };
      inputs = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              enabled = mkOption {
                type = types.bool;
                default = true;
                description = "Whether this lane may consume immutable inputs_from mounts.";
              };
              maxInputs = mkOption {
                type = positiveInteger;
                default = 8;
                description = "Maximum number of producer inputs bound to one destination run.";
              };
              maxBytes = mkOption {
                type = positiveInteger;
                default = 104857600;
                description = "Maximum total bytes across all bound input handoffs.";
              };
              maxEntries = mkOption {
                type = positiveInteger;
                default = 20000;
                description = "Maximum total manifest entries across all bound input handoffs.";
              };
              maxPathBytes = mkOption {
                type = positiveInteger;
                default = 4096;
                description = "Maximum byte length of one input manifest path.";
              };
            };
          }
        );
        default = null;
        description = "Immutable input ceilings for this lane; null disables inputs entirely.";
      };
    };
  };

  policyType = types.submodule {
    options = {
      worklane = mkOption {
        type = nullableString;
        default = null;
        description = "Broker policy worklane selected by trusted configuration.";
      };
      approvalPolicy = mkOption {
        type = types.enum [
          "never"
          "on-request"
          "untrusted"
          "always"
        ];
        default = "on-request";
        description = "Approval policy applied to worker operations.";
      };
      approvalReviewer = mkOption {
        type = nullableString;
        default = null;
        description = "Trusted approval reviewer identifier.";
      };
      networkAccess = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the external worker sandbox may use network access.";
      };
    };
  };

  executionType = types.submodule {
    options = {
      timeoutSeconds = mkOption {
        type = positiveInteger;
        default = 3600;
        description = "Maximum wall-clock runtime for one worker attempt.";
      };
      maxTurns = mkOption {
        type = positiveInteger;
        default = 40;
        description = "Maximum model turns for one worker attempt.";
      };
      cpus = mkOption {
        type = positiveInteger;
        default = 1;
        description = "Maximum virtual CPUs for the worker environment.";
      };
      memoryMiB = mkOption {
        type = positiveInteger;
        default = 2048;
        description = "Maximum worker memory in MiB.";
      };
      diskMiB = mkOption {
        type = positiveInteger;
        default = 8192;
        description = "Maximum worker disk allocation in MiB.";
      };
    };
  };

  workerLaneType = types.submodule {
    options = {
      description = mkOption {
        type = types.str;
        description = "Operator-facing description of the lane's worker role.";
      };
      runtime = mkOption {
        type = types.enum [
          "hermes"
          "external"
        ];
        description = "Runtime family used to execute this worker lane.";
      };
      profile = mkOption {
        type = nullableString;
        default = null;
        description = "Optional Hermes profile used as a configuration baseline.";
      };
      plugin = mkOption {
        type = nullableString;
        default = null;
        description = "External worker plugin registered for this lane.";
      };
      agent = mkOption {
        type = agentType;
        default = { };
        description = "Agent model, prompt, tool, and skill configuration.";
      };
      memory = mkOption {
        type = types.enum [
          "disabled"
          "lane"
          "shared-profile"
        ];
        default = "disabled";
        description = "Durable-memory mode; task transcripts remain run-scoped.";
      };
      workspace = mkOption {
        type = workspaceType;
        default = { };
        description = "Workspace provider and Project capability ceiling.";
      };
      policy = mkOption {
        type = policyType;
        default = { };
        description = "Broker worklane and approval behavior.";
      };
      execution = mkOption {
        type = executionType;
        default = { };
        description = "Hard execution and resource ceilings.";
      };
      maxConcurrency = mkOption {
        type = positiveInteger;
        default = 1;
        description = "Maximum concurrent attempts for this worker lane.";
      };
    };
  };

  boardType = types.submodule {
    options = {
      allowedLanes = mkOption {
        type = types.listOf types.str;
        description = "Global worker lanes permitted to participate on this board.";
      };
      allowedProjects = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Managed Projects permitted on this board.";
      };
      defaultProject = mkOption {
        type = nullableString;
        default = null;
        description = "Optional managed Project selected when a task omits one.";
      };
    };
  };

  projectType = types.submodule {
    options = {
      title = mkOption {
        type = types.str;
        description = "Operator-facing Project title.";
      };
      source = mkOption {
        type = types.submodule {
          options = {
            type = mkOption {
              type = types.enum [ "git" ];
              description = "Trusted Project source kind.";
            };
            repositoryId = mkOption {
              type = types.str;
              description = "Stable provider-side repository identity.";
            };
            defaultRef = mkOption {
              type = types.str;
              default = "main";
              description = "Default trusted source reference.";
            };
          };
        };
        description = "Nix-authoritative Project source identity.";
      };
      laneAccess = mkOption {
        type = types.attrsOf (
          types.enum [
            "read-only"
            "workspace-write"
          ]
        );
        default = { };
        description = "Maximum direct Project permission granted to each worker lane.";
      };
    };
  };

  # Trusted source credentials are exercised only by broker source
  # acquisition. The declaration carries a logical secret reference and an
  # adapter identity; values, store paths, environment names, argv, and
  # guest-visible paths are structurally inexpressible here.
  sourceCredentialType = types.submodule {
    options = {
      adapter = mkOption {
        type = types.enum [ "github-token" ];
        description = "Trusted credential adapter used for private source acquisition.";
      };
      secretRef = mkOption {
        type = types.strMatching "[a-z0-9][a-z0-9-]*";
        description = "Logical secret reference resolved by trusted infrastructure.";
      };
    };
  };

  # Nix-authoritative source acquisition declarations keyed by the logical
  # repositoryId that Projects reference. Model-facing catalogues never see
  # upstream URLs or credential references; the broker provider receives the
  # full descriptor through its trusted policy.
  sourceAdapterType = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [ "git" ];
        description = "Trusted source acquisition adapter kind.";
      };
      upstream = mkOption {
        type = types.str;
        description = "Trusted acquisition URL used only by the broker source provider.";
      };
      defaultRef = mkOption {
        type = types.str;
        default = "main";
        description = "Trusted source reference resolved when no pin applies.";
      };
      pin = mkOption {
        type = types.nullOr (types.strMatching "[0-9a-f]{40}");
        default = null;
        description = "Optional immutable commit pin selected for every acquisition.";
      };
      credential = mkOption {
        type = types.nullOr sourceCredentialType;
        default = null;
        description = "Trusted credential adapter for private acquisition; logical reference only.";
      };
    };
  };

  legacyPayload =
    description:
    mkOption {
      type = types.attrsOf types.anything;
      default = { };
      inherit description;
    };

  optionalString =
    description:
    mkOption {
      type = nullableString;
      default = null;
      inherit description;
    };
in
{
  instance = mkOption {
    type = types.str;
    description = "Stable Hermes instance name.";
  };
  config = legacyPayload "Upstream Hermes configuration payload.";
  tailscale = mkOption {
    type = types.submodule {
      options.hostname = mkOption { type = types.str; };
    };
    description = "Tailscale sidecar configuration.";
  };
  fortress = legacyPayload "Existing browser fortress sidecar configuration.";
  secureTerminal = legacyPayload "Existing secure terminal backend and policy configuration.";
  codex = legacyPayload "Existing external Codex worker integration configuration.";
  image = optionalString "Hermes OCI image reference.";
  project = legacyPayload "Existing single-Project bootstrap configuration.";
  repository = optionalString "Existing Project repository URL.";
  restartDrainTimeout = mkOption {
    type = positiveInteger;
    default = 120;
    description = "Worker drain timeout used during service restart.";
  };
  soul = optionalString "Interactive Hermes SOUL contents.";
  workerLanes = mkOption {
    type = types.attrsOf workerLaneType;
    default = { };
    description = "Instance-wide explicit worker-lane declarations keyed by stable lane name.";
  };
  boards = mkOption {
    type = types.attrsOf boardType;
    default = { };
    description = "Instance-wide boards and their permitted lanes and Projects.";
  };
  projects = mkOption {
    type = types.attrsOf projectType;
    default = { };
    description = "Instance-wide Nix-authoritative managed Project catalogue.";
  };
  projectSources = mkOption {
    type = types.attrsOf sourceAdapterType;
    default = { };
    description = "Instance-wide trusted Project source adapters keyed by logical repositoryId.";
  };
}
