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
      ./worker-lanes.patch
      ./worker-lane-discovery.patch
      ./kanban-platform-toolsets.patch
      ./secure-terminal-isolation.patch
      ./gondolin-backend.patch
      ./gondolin-hard-cancel.patch
      ./task-authority-binding.patch
      ./workspace-service.patch
      ./workspace-kanban.patch
      ./workspace-lifecycle.patch
      ./workspace-handoff.patch
      ./workspace-finalizers.patch
      ./workspace-schemas.patch
      ./workspace-integration.patch
      ./approval-choice-result.patch
      ./approval-permanent-control.patch
      ./approval-surface-permanent-control.patch
      ./approval-rich-choice-control.patch
      ./workspace-finalization-exit-recovery.patch
      ./kanban-triage-loop-breaker.patch
      ./kanban-protocol-violation-sticky.patch
      ./worker-lane-workspace-policy.patch
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
