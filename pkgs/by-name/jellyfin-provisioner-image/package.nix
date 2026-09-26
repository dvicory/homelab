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
  nss_wrapper,
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
    # Keep pname = "jellyfin": upstream postFixup reads $out/lib/jellyfin.
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
      trap 'rm -f /run/provision/provision.json /run/provision/provision.json.tmp /run/provision/passwd /run/provision/group' EXIT

      # The image has no /etc/passwd. Jellyfin reads Environment.UserName,
      # which fails unless the runtime uid resolves, so nss_wrapper supplies
      # entries for whatever uid and gid the pod runs as.
      uid="$(id -u)"
      gid="$(id -g)"
      printf 'root:x:0:0:root:/root:/bin/false\njellyfin:x:%s:%s:jellyfin:/config:/bin/false\n' \
        "$uid" "$gid" > /run/provision/passwd
      printf 'root:x:0:\njellyfin:x:%s:\n' "$gid" > /run/provision/group

      jq -n --rawfile password /run/secrets/password '{
        Administrator: { Name: "daniel", Password: ($password | rtrimstr("\n")) }
      }' > /run/provision/provision.json.tmp
      mv /run/provision/provision.json.tmp /run/provision/provision.json

      # /cache is the pod's writable emptyDir; fontconfig and .NET need a
      # writable HOME.
      HOME=/cache \
        LD_PRELOAD=${nss_wrapper}/lib/libnss_wrapper.so \
        NSS_WRAPPER_PASSWD=/run/provision/passwd \
        NSS_WRAPPER_GROUP=/run/provision/group \
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
    inherit provisioner runner;
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
