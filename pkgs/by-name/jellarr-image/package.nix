{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  makeBinaryWrapper,
  nodejs_24,
  pnpm,
  fetchPnpmDeps,
  pnpmConfigHook,
  dockerTools,
  writeShellApplication,
}:
let
  version = "0.1.0";
  sourceRev = "f94c24f26c0264a7c331b016968d5b6e8d1504b7";
  imageName = "homelab/jellarr";
  imageTag = version;

  jellarr = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "jellarr";
    inherit version;

    src = fetchFromGitHub {
      owner = "venkyr77";
      repo = "jellarr";
      rev = sourceRev;
      hash = "sha256-J2r6XzNBcddW7kodls3TC6xb7fsSjUXIyR6ujinorIA=";
    };

    # Jellyfin 12 removed the legacy X-Emby-* auth headers that upstream
    # f94c24f sends; send the MediaBrowser Authorization scheme instead. The
    # patch also makes every call reject bodiless non-2xx responses, which
    # openapi-fetch otherwise reports without res.error.
    patches = [ ./jellyfin-12-auth.patch ];

    nativeBuildInputs = [
      makeBinaryWrapper
      nodejs_24
      pnpm
      pnpmConfigHook
    ];
    pnpmDeps = fetchPnpmDeps {
      fetcherVersion = 4;
      hash = "sha256-jo1BjRAjjfNKF0xb5cLCuELSveHeJ98iLPhMDKP1QbI=";
      inherit pnpm;
      inherit (finalAttrs) pname src version;
    };

    CI = "true";
    doCheck = true;

    buildPhase = ''
      runHook preBuild
      pnpm build
      runHook postBuild
    '';

    checkPhase = ''
      runHook preCheck
      pnpm test
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 -t "$out/share" bundle.cjs
      makeWrapper ${lib.getExe nodejs_24} "$out/bin/jellarr" \
        --add-flags "$out/share/bundle.cjs"
      runHook postInstall
    '';

    meta = {
      description = "Declarative Jellyfin configuration engine";
      homepage = "https://github.com/venkyr77/jellarr";
      license = lib.licenses.agpl3Only;
      mainProgram = "jellarr";
      platforms = lib.platforms.linux;
    };
  });

  runner = writeShellApplication {
    name = "jellarr";
    text = ''
      test -s /run/jellarr/api-key
      JELLARR_API_KEY="$(< /run/jellarr/api-key)"
      export JELLARR_API_KEY
      exec ${lib.getExe jellarr} --configFile /config/config.yml "$@"
    '';
  };

  image = dockerTools.buildLayeredImage {
    name = imageName;
    tag = imageTag;
    compressor = "none";
    contents = [
      runner
      nodejs_24
    ];
    config = {
      Entrypoint = [ "/bin/jellarr" ];
      Env = [
        "NODE_ENV=production"
        "PATH=${lib.makeBinPath [ nodejs_24 ]}:/bin:/usr/bin"
      ];
    };
  };
in
image.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    release = {
      inherit
        version
        sourceRev
        imageName
        imageTag
        ;
    };
  };
})
