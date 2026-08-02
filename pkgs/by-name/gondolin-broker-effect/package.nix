{
  lib,
  buildNpmPackage,
  git,
  makeWrapper,
  nodejs_24,
  python3,
}:
buildNpmPackage {
  pname = "gondolin-broker-effect";
  version = "0.1.0";

  src = ./.;
  nodejs = nodejs_24;
  nativeBuildInputs = [
    python3
    git
    makeWrapper
  ];

  # Gondolin's optional cpu-features extension is not needed. Keep install
  # hermetic and prevent dependency lifecycle scripts from running.
  npmFlags = [ "--ignore-scripts" ];
  npmInstallFlags = [ "--ignore-scripts" ];
  npmDepsHash = "sha256-Tdn2f64ZrJrsjStDejZTVrLUKono4+bCjaajy9BjJIc=";

  npmBuildScript = "build";

  # npm's workspace link points at the installed policy-kernel source tree,
  # but buildNpmPackage does not retain that workspace's gitignored dist/.
  # Preserve the compiled public package behind the link.
  postInstall = ''
    mkdir -p "$out/lib/node_modules/gondolin-broker-effect/policy-kernel/dist"
    cp -R policy-kernel/dist/. "$out/lib/node_modules/gondolin-broker-effect/policy-kernel/dist/"
  '';

  # The source adapter invokes Git as a subprocess. Keep Git in the package's
  # runtime closure instead of relying on a particular systemd unit PATH.
  postFixup = ''
    wrapProgram "$out/bin/gondolin-broker-effect" \
      --prefix PATH : "${lib.makeBinPath [ git ]}"
  '';


  doCheck = true;
  checkPhase = ''
    runHook preCheck
    node --test policy-kernel/test/*.test.mjs test/*.test.mjs
    python3 test/activation-smoke.py
    node --check test/qa-workspace-smoke.mjs
    runHook postCheck
  '';

  meta = {
    description = "Effect-based HTTP broker for Gondolin/QEMU sandboxes";
    mainProgram = "gondolin-broker-effect";
    platforms = lib.platforms.linux ++ [ "aarch64-darwin" ];
  };
}
