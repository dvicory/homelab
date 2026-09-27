{
  lib,
  stdenv,
  buildGoModule,
  makeWrapper,
  kubectl,
  yq-go,
  nix,
  openssh,
  util-linux,
}:
buildGoModule {
  pname = "compute-runtime";
  version = "0-unstable";
  src = lib.cleanSource ./.;
  vendorHash = "sha256-TKtUFKvQPnYAIzFpcGKSSZyXRvRjfhLRd91ibNq6HMI=";

  subPackages = [
    "cmd/household-bootstrap"
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    "cmd/compute-guest"
    "cmd/household-bootstrap-host"
  ];

  # subPackages selects installed commands, not the internal safety tests.
  checkPhase = ''
    runHook preCheck
    export GOFLAGS=''${GOFLAGS//-trimpath/}
    buildGoDir test ./...
    runHook postCheck
  '';

  nativeBuildInputs = [ makeWrapper ];
  postInstall = ''
    wrapProgram "$out/bin/household-bootstrap" \
      --prefix PATH : ${
        lib.makeBinPath [
          kubectl
          yq-go
        ]
      }
  ''
  + lib.optionalString stdenv.hostPlatform.isLinux ''
    wrapProgram "$out/bin/compute-guest" \
      --prefix PATH : ${
        lib.makeBinPath [
          nix
          openssh
          util-linux
        ]
      }
    wrapProgram "$out/bin/household-bootstrap-host" \
      --prefix PATH : "$out/bin:${
        lib.makeBinPath [
          kubectl
          yq-go
        ]
      }"
  '';

  meta = {
    description = "Declared compute lifecycle and household bootstrap commands";
    mainProgram = if stdenv.hostPlatform.isLinux then "compute-guest" else "household-bootstrap";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
