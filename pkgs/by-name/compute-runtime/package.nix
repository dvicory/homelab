{
  lib,
  buildGoModule,
  makeWrapper,
  nix,
  openssh,
  util-linux,
}:
buildGoModule {
  pname = "compute-runtime";
  version = "0-unstable";
  src = lib.cleanSource ./.;
  vendorHash = "sha256-TKtUFKvQPnYAIzFpcGKSSZyXRvRjfhLRd91ibNq6HMI=";

  subPackages = [ "cmd/compute-guest" ];

  # subPackages selects installed commands, not the internal safety tests.
  checkPhase = ''
    runHook preCheck
    export GOFLAGS=''${GOFLAGS//-trimpath/}
    buildGoDir test ./...
    runHook postCheck
  '';

  nativeBuildInputs = [ makeWrapper ];
  postInstall = ''
    wrapProgram "$out/bin/compute-guest" \
      --prefix PATH : ${
        lib.makeBinPath [
          nix
          openssh
          util-linux
        ]
      }
  '';

  meta = {
    description = "Declared compute guest lifecycle command";
    mainProgram = "compute-guest";
    platforms = lib.platforms.linux;
  };
}
