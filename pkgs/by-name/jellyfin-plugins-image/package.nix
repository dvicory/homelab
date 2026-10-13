{
  lib,
  fetchurl,
  runCommand,
  unzip,
  jq,
  coreutils,
  dockerTools,
  writeShellApplication,
}:
let
  # Jellyfin's official LDAP plugin, from the official repository manifest
  # (https://repo.jellyfin.org/files/plugin/manifest.json). A Jellyfin
  # upgrade must re-check targetAbi; jellyfin.nix rejects a mismatch.
  ldap = {
    # The manifest and repository name; Jellyfin loads the plugin from
    # /config/plugins/<name>_<version>.
    name = "LDAP Authentication";
    # The name Jellyfin's plugin API reports for the loaded plugin. Jellarr
    # finds the plugin by it; no repository offers a package of that name.
    serverName = "LDAP-Auth";
    guid = "958aad66-3784-4d2a-b89a-a7b6fab6e25c";
    version = "24.0.0.0";
    targetAbi = "12.0.0.0";
    # Upstream tag v24; the release zip is built by upstream CI from it.
    sourceRev = "d11c86a47d51a0e3372bbff20e508302ad78f7bd";
    src = fetchurl {
      url = "https://repo.jellyfin.org/files/plugin/ldap-authentication/ldap-authentication_24.0.0.0.zip";
      hash = "sha256-O+H51qbOnqN15VbdMBNtF4qNvjXL6GbTDTRR3D/36AQ=";
    };
  };
  plugins = [ ldap ];

  # Jellyfin loads a plugin from /config/plugins/<name>_<version>. The
  # manifest is checked against the declaration, and autoUpdate is off so
  # Jellyfin's Update Plugins task never replaces the pinned build.
  unpack =
    plugin:
    runCommand "jellyfin-plugin-${lib.toLower (lib.replaceStrings [ " " ] [ "-" ] plugin.name)}-${plugin.version}"
      {
        nativeBuildInputs = [
          unzip
          jq
        ];
        passthru = plugin // {
          directory = "${plugin.name}_${plugin.version}";
        };
      }
      ''
        mkdir -p "$out"
        unzip -q ${plugin.src} -d "$out"
        jq -e --arg name ${lib.escapeShellArg plugin.name} --arg guid ${plugin.guid} \
          --arg version ${plugin.version} --arg abi ${plugin.targetAbi} \
          '.name == $name and .guid == $guid and .version == $version and .targetAbi == $abi' \
          "$out/meta.json" > /dev/null
        jq '.autoUpdate = false' "$out/meta.json" > meta.json
        mv meta.json "$out/meta.json"
      '';
  unpacked = map unpack plugins;

  installer = writeShellApplication {
    name = "jellyfin-install-plugins";
    runtimeInputs = [ coreutils ];
    text = ''
      root=/config/plugins
      test -d /config
      mkdir -p "$root"
      shopt -s nullglob
    ''
    + lib.concatMapStrings (plugin: ''
      # ${plugin.name}: keep only the pinned build. Other versions of it,
      # such as one a repository update installed, are removed.
      for existing in "$root"/${lib.escapeShellArg plugin.name}_*; do
        if [ "$existing" != "$root"/${lib.escapeShellArg plugin.directory} ]; then
          rm -rf -- "$existing"
        fi
      done
      rm -rf -- "$root"/${lib.escapeShellArg "${plugin.directory}.new"}
      cp -R ${plugin} "$root"/${lib.escapeShellArg "${plugin.directory}.new"}
      chmod -R u+w "$root"/${lib.escapeShellArg "${plugin.directory}.new"}
      rm -rf -- "$root"/${lib.escapeShellArg plugin.directory}
      mv "$root"/${lib.escapeShellArg "${plugin.directory}.new"} "$root"/${lib.escapeShellArg plugin.directory}
      echo "jellyfin-install-plugins: installed ${plugin.directory}"
    '') unpacked;
  };

  image = dockerTools.buildLayeredImage {
    name = "homelab/jellyfin-plugins";
    compressor = "none";
    contents = [ installer ];
    config.Entrypoint = [ "${installer}/bin/jellyfin-install-plugins" ];
  };
in
image.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit installer;
    plugins = map (plugin: plugin.passthru // { files = plugin; }) unpacked;
    imageReference = "${image.imageName}:${image.imageTag}";
  };
})
