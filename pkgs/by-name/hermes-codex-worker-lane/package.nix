{
  lanes ? [
    {
      name = "codex-plan";
      description = "read-only software architecture, investigation, planning, and code review";
      approvalPolicy = "never";
      approvalsReviewer = "user";
      sandboxMode = "read-only";
      networkAccess = false;
      maxConcurrency = 1;
    }
    {
      name = "codex";
      description = "implementation, debugging, refactoring, and verification that may modify files";
      approvalPolicy = "never";
      approvalsReviewer = "user";
      sandboxMode = "workspace-write";
      networkAccess = false;
      maxConcurrency = 1;
    }
  ],
  lib,
  stdenvNoCC,
  writeText,
}:
let
  laneNames = map (lane: lane.name or null) lanes;
  validLane =
    lane:
    builtins.isAttrs lane
    && builtins.isString (lane.name or null)
    && builtins.match "[a-z0-9][a-z0-9_-]{0,63}" lane.name != null
    && lane.name != "default"
    && builtins.isString (lane.description or null)
    && lane.description != ""
    && !lib.hasInfix "\n" lane.description
    && lib.elem (lane.sandboxMode or null) [
      "read-only"
      "workspace-write"
    ]
    && (lane.approvalPolicy or null) == "never"
    && lib.elem (lane.approvalsReviewer or null) [
      "user"
      "auto_review"
    ]
    && builtins.isBool (lane.networkAccess or null)
    && builtins.isInt (lane.maxConcurrency or null)
    && lane.maxConcurrency >= 1;
  laneGuide = lib.concatMapStringsSep "\n" (lane: ''
    - `${lane.name}` — ${lane.description}.
      Codex-native policy: sandbox `${lane.sandboxMode}`, network ${
        if lane.networkAccess then "enabled" else "disabled"
      }, approvals `${lane.approvalPolicy}` reviewed by `${lane.approvalsReviewer}`.
  '') lanes;
  skillFile = writeText "hermes-codex-worker-lane-SKILL.md" (
    builtins.replaceStrings [ "@lane-guide@" ] [ laneGuide ] (builtins.readFile ./SKILL.md)
  );
in
assert lib.assertMsg (lanes != [ ]) "hermes-codex-worker-lane requires at least one lane";
assert lib.assertMsg (lib.all validLane lanes) "invalid Hermes Codex worker lane declaration";
assert lib.assertMsg (
  lib.length (lib.unique laneNames) == lib.length laneNames
) "Hermes Codex worker lane names must be unique";
stdenvNoCC.mkDerivation {
  pname = "hermes-codex-worker-lane";
  version = "0.1.0";
  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    pluginDir=$out/share/hermes-agent/plugins/codex-worker-lane
    mkdir -p "$pluginDir"
    cp __init__.py worker.py codex-output-schema.json plugin.yaml "$pluginDir"/

    skillDir=$out/share/hermes-agent/external-skills/codex
    install -Dm444 ${skillFile} "$skillDir/SKILL.md"

    runHook postInstall
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck

    grep -Fx 'name: codex' ${skillFile}
    grep -F 'kanban_create' ${skillFile}
    grep -F 'Every delegated Codex task receives its own project-backed worktree' ${skillFile}
    grep -F 'exact source branch or commit' ${skillFile}
    grep -F 'it does not select a Git revision' ${skillFile}
    if grep -F 'workspace_kind' ${skillFile}; then
      echo "The managed Codex skill must not select a workspace mechanism" >&2
      exit 1
    fi
    if grep -F '@lane-guide@' ${skillFile}; then
      echo "The managed Codex skill still contains an unsubstituted lane guide" >&2
      exit 1
    fi
    ${lib.concatMapStringsSep "\n" (lane: ''
      grep -F -- ${lib.escapeShellArg "`${lane.name}`"} ${skillFile}
      grep -F -- ${lib.escapeShellArg lane.description} ${skillFile}
    '') lanes}

    if grep -Eiq -- 'codex exec|--yolo|danger-full-access|terminal\(' ${skillFile}; then
      echo "The managed Codex skill must route through Kanban, not invoke Codex directly" >&2
      exit 1
    fi

    runHook postCheck
  '';

  passthru.testSource = ./.;

  meta = {
    description = "Hermes Kanban worker lane and routing skill backed by Codex CLI";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
