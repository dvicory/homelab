{
  lib,
  stdenvNoCC,
}:
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

    runHook postInstall
  '';

  passthru.testSource = ./.;

  meta = {
    description = "Hermes Kanban worker lane backed by Codex CLI";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
