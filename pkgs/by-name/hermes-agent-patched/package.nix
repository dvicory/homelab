{
  applyPatches,
  hermesAgent,
  makeWrapper,
  src,
}:
let
  patchedSource = applyPatches {
    name = "hermes-agent-patched-source";
    inherit src;
    patches = [
      # Generic Hermes worker-lane and platform toolset support.
      ./worker-lanes.patch
      ./worker-lane-discovery.patch
      # Generic trusted catalogue types and deterministic resolution.
      ./worker-catalogue.patch
      ./kanban-platform-toolsets.patch
      # Secure-terminal and Gondolin execution backend.
      ./secure-terminal-isolation.patch
      ./gondolin-backend.patch
      # Hashless Gondolin workspace broker lifecycle, operation journal, and
      # trusted direct-child handoff.
      ./workspace-handoff.patch
      # Hermes task hooks, broker-worker validation, and native attachment
      # delivery. Generic worker lanes remain in the patches above.
      ./workspace-integration.patch
      # Canonical approval choices and caller-scoped durable-grant policy.
      ./approval-tool-contract.patch
      ./kanban-triage-loop-breaker.patch
      ./kanban-lifecycle-safety.patch
      ./worker-lane-workspace-policy.patch
      ./kanban-worker-guidance.patch
      # Stable conversation workspace ownership and private branch preparation.
      ./workspace-resume-identity.patch
      # Pin broker task workers to their pre-spawn environment, propagate
      # required finalization failures, and surface loop-breaker triage.
      ./workspace-runtime-identity.patch
      # Use one board-qualified task/run identity across broker control and
      # execution requests.
      ./workspace-task-run-identity.patch
      # Persist resolved specifications through existing task event/run metadata.
      ./worker-spec-persistence.patch
      # Cut dispatch and the model-facing API over to explicit catalogue lanes.
      ./explicit-worker-routing.patch
      # Apply frozen lane behavior in spawned Hermes and external workers.
      ./worker-lane-agent-behavior.patch
      # Process-local opaque environment identities remain separate from
      # ordinary terminal overrides and are covered by concurrency tests.
      ./task-authority-registry.patch
      # Atomically bind the frozen lane worklane while activating a task run.
      ./task-authority-binding.patch
      # Resolve worker behavior from the lease-fenced durable run rather than
      # copying specification and authority fields into the process environment.
      ./durable-worker-specification.patch
      # Restrict managed task creation to intent and declared lane selection.
      ./managed-task-api.patch
      # Bind the complete durable worker authority into each broker task-run.
      ./task-authority-facts.patch
      # Let external workers request only opaque task-run identity variables.
      ./worker-identity-env.patch
      # Resolve backend, workspace, and prompt surfaces from the durable run.
      ./worker-authority-surfaces.patch
      # Give broker-owned scratch workspaces writable task authority without
      # granting any Project source authority.
      ./scratch-workspace-authority.patch
      # Tell live orchestrators that identically named worker paths remain
      # unreachable across isolated conversation and task environments.
      ./orchestrator-workspace-boundary.patch
      # Generic fail-closed completion and native attachment materialization.
      ./workspace-handoff-finalization.patch
      # Downstream Hermes/Gondolin bridge cutover; no writable inheritance.
      ./workspace-handoff-gondolin-integration.patch
    ];
    postPatch = ''
      rm -f \
        agent/prompt_builder.py.orig \
        hermes_cli/kanban_db.py.orig \
        hermes_cli/plugins.py.orig \
        tests/tools/test_kanban_tools.py.orig \
        tools/kanban_tools.py.orig \
        tools/terminal_tool.py.orig
    '';
  };
in
hermesAgent.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ makeWrapper ];
  postFixup = (old.postFixup or "") + ''
    # Upstream's flake seals its Python venv and separately points plugin
    # discovery at $out/share/hermes-agent/plugins. Replace that tree itself:
    # an additional outer wrapper cannot override the inner wrapper's
    # unconditional HERMES_BUNDLED_PLUGINS assignment.
    rm -rf "$out/share/hermes-agent/plugins"
    ln -s "${patchedSource}/plugins" "$out/share/hermes-agent/plugins"

    # Prepending the fully patched source keeps the upstream dependency graph
    # while ensuring all ordinary Hermes Python modules come from one tree.
    for program in hermes hermes-agent hermes-acp; do
      wrapProgram "$out/bin/$program" \
        --prefix PYTHONPATH : "${patchedSource}"
    done
  '';
  passthru = (old.passthru or { }) // {
    patchedSource = patchedSource;
  };
})
