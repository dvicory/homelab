{
  lib,
  fetchurl,
  runCommand,
  unzip,
  jq,
  coreutils,
  writeShellApplication,
}:
let
  # Jellyfin's official LDAP plugin, from the official repository manifest
  # (https://repo.jellyfin.org/files/plugin/manifest.json). A Jellyfin
  # upgrade must re-check targetAbi.
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
  };
  src = fetchurl {
    url = "https://repo.jellyfin.org/files/plugin/ldap-authentication/ldap-authentication_24.0.0.0.zip";
    hash = "sha256-O+H51qbOnqN15VbdMBNtF4qNvjXL6GbTDTRR3D/36AQ=";
  };
  directory = "${ldap.name}_${ldap.version}";

  # Jellyfin loads a plugin from /config/plugins/<name>_<version>. The
  # manifest is checked against the declaration, and autoUpdate is off so
  # Jellyfin's Update Plugins task never replaces the pinned build.
  files =
    runCommand "jellyfin-plugin-ldap-authentication-${ldap.version}"
      {
        nativeBuildInputs = [
          unzip
          jq
        ];
      }
      ''
        mkdir -p "$out"
        unzip -q ${src} -d "$out"
        jq -e --arg name ${lib.escapeShellArg ldap.name} --arg guid ${ldap.guid} \
          --arg version ${ldap.version} --arg abi ${ldap.targetAbi} \
          '.name == $name and .guid == $guid and .version == $version and .targetAbi == $abi' \
          "$out/meta.json" > /dev/null
        jq '.autoUpdate = false' "$out/meta.json" > meta.json
        mv meta.json "$out/meta.json"
      '';

  installer = writeShellApplication {
    name = "jellyfin-install-plugins";
    runtimeInputs = [ coreutils ];
    text = ''
      root=/config/plugins
      test -d /config
      mkdir -p "$root"
      shopt -s nullglob
      # ${ldap.name}: keep only the pinned build. Other versions of it,
      # such as one a repository update installed, are removed.
      for existing in "$root"/${lib.escapeShellArg ldap.name}_*; do
        if [ "$existing" != "$root"/${lib.escapeShellArg directory} ]; then
          rm -rf -- "$existing"
        fi
      done
      rm -rf -- "$root"/${lib.escapeShellArg "${directory}.new"}
      cp -R ${files} "$root"/${lib.escapeShellArg "${directory}.new"}
      chmod -R u+w "$root"/${lib.escapeShellArg "${directory}.new"}
      rm -rf -- "$root"/${lib.escapeShellArg directory}
      mv "$root"/${lib.escapeShellArg "${directory}.new"} "$root"/${lib.escapeShellArg directory}
      echo "jellyfin-install-plugins: installed ${directory}"
    '';
  };
in
installer.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    ldapPlugin = ldap // {
      inherit directory files;
    };
  };
})
