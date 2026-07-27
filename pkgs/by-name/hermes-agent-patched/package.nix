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
      ./kanban-platform-toolsets.patch
      # Secure-terminal and Gondolin execution backend.
      ./secure-terminal-isolation.patch
      ./gondolin-backend.patch
      ./task-authority-binding.patch
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
    ];
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
    # Compatibility alias for the worker-lane plugin/check while downstream
    # consumers migrate to the capability-neutral package name.
    workerLanesSource = patchedSource;
  };
})
