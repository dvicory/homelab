{
  lib,
  rustPlatform,
  bash,
}:
rustPlatform.buildRustPackage {
  pname = "homelab-preserve";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  cargoLock.lockFile = ./Cargo.lock;
  checkFlags = [ "--test-threads=1" ];
  HOMELAB_PRESERVE_TEST_SHELL = "${bash}/bin/bash";

  meta = {
    description = "State-protection inspection, safe owner dispatch, and recovery verification";
    mainProgram = "homelab-preserve";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
