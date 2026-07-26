{
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "hermes-sandbox-access";
  version = "0.1.0";
  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    pluginDir=$out/share/hermes-agent/plugins/sandbox-access
    mkdir -p "$pluginDir"
    cp __init__.py plugin.yaml "$pluginDir"/

    runHook postInstall
  '';

  passthru.testSource = ./.;

  meta = {
    description = "Hermes plugin for broker-prepared sandbox capability approvals";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
