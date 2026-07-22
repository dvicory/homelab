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
      ./approval-choice-result.patch
      ./approval-permanent-control.patch
      ./approval-surface-permanent-control.patch
      ./approval-rich-choice-control.patch
    ];
  };
in
hermesAgent.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ makeWrapper ];
  postFixup = (old.postFixup or "") + ''
    # Upstream's flake seals its Python venv and separately points plugin
    # discovery at the unpatched package tree. Select the fully patched source
    # for both normal imports and bundled plugin loading so migrated platform
    # adapters (including Telegram) cannot drift from the patched gateway.
    for program in hermes hermes-agent hermes-acp; do
      wrapProgram "$out/bin/$program" \
        --prefix PYTHONPATH : "${patchedSource}" \
        --set HERMES_BUNDLED_PLUGINS "${patchedSource}/plugins"
    done
  '';
  passthru = (old.passthru or { }) // {
    patchedSource = patchedSource;
    # Compatibility alias for the worker-lane plugin/check while downstream
    # consumers migrate to the capability-neutral package name.
    workerLanesSource = patchedSource;
  };
})
