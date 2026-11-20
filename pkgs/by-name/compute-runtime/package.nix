{
  lib,
  stdenv,
  buildGoModule,
  go,
  fetchurl,
  makeWrapper,
  kubectl,
  yq-go,
  nix,
  openssh,
  util-linux,
}:
let
  # Keep a security-fixed compiler without overriding newer fleet versions.
  securityGo =
    if lib.versionAtLeast go.version "1.26.11" then
      go
    else
      go.overrideAttrs {
        version = "1.26.11";
        src = fetchurl {
          url = "https://go.dev/dl/go1.26.11.src.tar.gz";
          hash = "sha256-1EEBsP8n7SpMda1GwXucdDWSCeLrLKfJ32y0/baOGWk=";
        };
      };
in
(buildGoModule.override { go = securityGo; }) {
  pname = "compute-runtime";
  version = "0-unstable";
  src = lib.cleanSource ./.;
  vendorHash = "sha256-hZXoEaZZFHXpvPB4Pmn8qqiYS1SXKCWGpmyqdSb+IRQ=";

  subPackages = [
    "cmd/household-bootstrap"
    "cmd/retained-directories"
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
