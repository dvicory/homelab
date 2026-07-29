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
        type = types.str;
        default = "broker-scratch";
        description = "Trusted workspace provider used for non-Project tasks.";
      };
      projectProvider = mkOption {
        type = nullableString;
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
      type = types.str;
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
}
