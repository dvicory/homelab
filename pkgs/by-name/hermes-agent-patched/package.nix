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
      ./task-authority-binding.patch
      ./approval-choice-result.patch
    ];
  };
in
hermesAgent.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ makeWrapper ];
  postFixup = (old.postFixup or "") + ''
    # Upstream's flake seals its Python venv and does not expose a source
    # override. Prepending the fully patched source keeps its dependency graph
    # while ensuring all Hermes Python modules come from one coherent tree.
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
