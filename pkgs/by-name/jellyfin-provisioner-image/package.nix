{
  lib,
  buildDotnetModule,
  fetchFromGitHub,
  fetchpatch,
  dotnetCorePackages,
  sqlite,
  fontconfig,
  freetype,
  dockerTools,
  writeShellApplication,
  jq,
  coreutils,
}:
let
  version = "12.1";
  sourceRev = "ee91c75e777da41a9c4f4855e70adc604fbf2ef8";
  provisionPatchRev = "8b0a2c269d5a3d9d7084b5295fd818a8a67af6f2";
  runtimeImage = "docker.io/jellyfin/jellyfin:12.1";
  runtimeDigest = "sha256:78d3ea1207d1322471fcac39a614f004f2ccf7e878f95ab2977d752f07e4dd7e";

  provisioner = buildDotnetModule (finalAttrs: {
    pname = "jellyfin-provisioner";
    inherit version;

    src = fetchFromGitHub {
      owner = "jellyfin";
      repo = "jellyfin";
      rev = sourceRev;
      hash = "sha256-WB/miD5uwoCY9DcTRRtxxOu9G+jojNGp5FZ0HHDqhys=";
    };

    patches = [
      (fetchpatch {
        url = "https://github.com/jellyfin/jellyfin/commit/${provisionPatchRev}.patch";
        hash = "sha256-pgCNgOP27SHgf0wUmYqxxytJSym2vI2MIOG17JWpoAA=";
      })
    ];

    propagatedBuildInputs = [ sqlite ];
    projectFile = "Jellyfin.Server/Jellyfin.Server.csproj";
    executables = [ "jellyfin" ];
    nugetDeps = ./nuget-deps.json;
    dotnet-sdk = dotnetCorePackages.sdk_10_0;
    dotnet-runtime = dotnetCorePackages.aspnetcore_10_0;
    dotnetBuildFlags = [ "--no-self-contained" ];

    # Provision mode skips media-server startup (and therefore ffmpeg). The
    # pinned Jellyfin recipe's fontconfig/freetype deps remain for Skia's
    # static typeface initialization during provider discovery.
    runtimeDeps = [
      sqlite
      fontconfig
      freetype
    ];
    makeWrapperArgs = [ ];
    nativeInstallCheckInputs = [ ];
    doInstallCheck = false;

    meta = {
      description = "Minimal Jellyfin startup provisioner image payload";
      homepage = "https://jellyfin.org/";
      license = lib.licenses.gpl2Plus;
      mainProgram = "jellyfin";
      platforms = finalAttrs.dotnet-runtime.meta.platforms;
    };
  });

  runner = writeShellApplication {
    name = "jellyfin-provision";
    runtimeInputs = [
      provisioner
      jq
      coreutils
    ];
    text = ''
      umask 077
      test -s /run/secrets/password
      trap 'rm -f /run/provision/provision.json /run/provision/provision.json.tmp' EXIT
      jq -n --rawfile password /run/secrets/password '{
        Administrator: { Name: "daniel", Password: ($password | rtrimstr("\n")) }
      }' > /run/provision/provision.json.tmp
      mv /run/provision/provision.json.tmp /run/provision/provision.json
      jellyfin --nowebclient --mode Provision --provision-file /run/provision/provision.json
    '';
  };

  image = dockerTools.buildLayeredImage {
    name = "homelab/jellyfin-provisioner";
    tag = version;
    compressor = "none";
    contents = [ runner ];
    config = {
      Entrypoint = [ "${runner}/bin/jellyfin-provision" ];
      Env = [
        "JELLYFIN_DATA_DIR=/config"
        "JELLYFIN_CONFIG_DIR=/config/config"
        "JELLYFIN_LOG_DIR=/config/log"
        "JELLYFIN_CACHE_DIR=/cache"
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
        runtimeImage
        runtimeDigest
        provisionPatchRev
        ;
    };
  };
})
