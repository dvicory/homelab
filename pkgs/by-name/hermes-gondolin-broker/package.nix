{
  lib,
  buildNpmPackage,
  nodejs_22,
}:

# Hermes Gondolin broker (V3 §13): the trusted, profile-scoped mediation
# boundary between the Hermes gateway and Gondolin/QEMU sandboxes. Node 22,
# systemd socket activation, immutable policy JSON, per-VM cgroups.
buildNpmPackage {
  pname = "hermes-gondolin-broker";
  version = "0.1.0";

  src = ./.;

  nodejs = nodejs_22;

  # The lockfile pins the dependency tree (including the Gondolin SDK).
  # --ignore-scripts: ssh2's optional cpu-features native build is not
  # needed (ssh2 works without it), and no lifecycle scripts must run in
  # the sandbox.
  npmFlags = [ "--ignore-scripts" ];
  npmInstallFlags = [ "--ignore-scripts" ];

  npmDepsHash = "sha256-2c5MIjg7au90BSdJg7R4qxwqmtpQTG2SntND4YL2LjY=";

  npmBuildScript = "build"; # tsc -p tsconfig.json → dist/

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    node --test test/*.test.mjs
    runHook postCheck
  '';

  meta = {
    description = "Hermes secure terminal broker for Gondolin/QEMU sandboxes";
    mainProgram = "hermes-gondolin-broker";
    # The broker service runs on Linux, but the package and its test suite
    # are portable: tests fake the Gondolin provider boundary and never
    # require QEMU/KVM, so the check also runs on darwin dev machines.
    platforms = lib.platforms.linux ++ [ "aarch64-darwin" ];
  };
}
