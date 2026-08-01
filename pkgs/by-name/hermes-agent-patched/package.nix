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
      # immutable selected-output handoff.
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
      # Stable conversation ownership, pre-spawn broker identity, and one
      # board-qualified task/run identity across control and execution.
      ./workspace-runtime-identity.patch
      # Persist and route workers from one frozen catalogue lane specification.
      ./durable-worker-routing.patch
      # Bind the complete durable task-run authority and derive every worker
      # surface from it instead of process-environment capability data.
      ./task-authority.patch
      # Downstream Hermes/Gondolin bridge cutover and immutable handoff wiring.
      ./workspace-handoff-gondolin-integration.patch
      # Bind task runs to durable three-plane broker project workspaces and
      # expose typed resolve/authority calls for trusted external workers.
      ./broker-project-workspaces.patch
      # Explicit immutable producer edges and exact destination input pins.
      ./multi-task-inputs.patch
      # Trusted preparation, activation, release, and archive-gated reclaim.
      ./multi-task-input-lifecycle.patch
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
