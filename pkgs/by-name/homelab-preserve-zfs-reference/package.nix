{
  lib,
  rustPlatform,
  makeWrapper,
  zfs,
  coreutils,
}:
rustPlatform.buildRustPackage {
  pname = "homelab-preserve-zfs-reference";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram "$out/bin/homelab-preserve-zfs-reference" \
      --prefix PATH : ${
        lib.makeBinPath [
          zfs
          coreutils
        ]
      }
  '';

  meta = {
    description = "Fixture-only direct-ZFS conformance adapter for homelab-preserve";
    mainProgram = "homelab-preserve-zfs-reference";
    platforms = lib.platforms.linux;
  };
}
