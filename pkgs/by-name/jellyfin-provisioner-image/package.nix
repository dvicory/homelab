{
  lib,
  fetchFromGitHub,
  jellyfinMultiverse,
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
  provisionerRuntimeDeps = [
    sqlite
    fontconfig
    freetype
  ];

  provisioner = (jellyfinMultiverse.version "jellyfin" version).overrideAttrs {
    pname = "jellyfin-provisioner";

    src = fetchFromGitHub {
      owner = "jellyfin";
      repo = "jellyfin";
      rev = sourceRev;
      hash = "sha256-WB/miD5uwoCY9DcTRRtxxOu9G+jojNGp5FZ0HHDqhys=";
    };

    # PR #17902: https://github.com/jellyfin/jellyfin/commit/8b0a2c269d5a3d9d7084b5295fd818a8a67af6f2
    # Vendored fetchpatch output, sha256-pgCNgOP27SHgf0wUmYqxxytJSym2vI2MIOG17JWpoAA=.
    patches = [ ./provision.patch ];

    # buildDotnetModule captures runtimeDeps before overrideAttrs. Replace both
    # to exclude upstream ffmpeg while retaining the Skia font libraries.
    runtimeDeps = provisionerRuntimeDeps;
    dotnetRuntimeDeps = map lib.getLib provisionerRuntimeDeps;
    makeWrapperArgs = [ ];
    nativeInstallCheckInputs = [ ];
    doInstallCheck = false;
  };

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
