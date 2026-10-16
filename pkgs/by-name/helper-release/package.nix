{ lib, writeShellApplication, writeText, python3, nix, skopeo }:
let
  # Nix-built helpers are unsigned. Source/manifest hashes and verified TLS
  # establish this release's identity; do not imply an OCI signature proof.
  policy = writeText "helper-release-policy.json" (builtins.toJSON {
    default = [ { type = "reject"; } ];
    transports = builtins.listToAttrs (map (name: {
      inherit name;
      value."" = [ { type = "insecureAcceptAnything"; } ];
    }) [ "docker-archive" "docker" ]);
  });
in
writeShellApplication {
  name = "helper-release";
  runtimeInputs = [ python3 nix skopeo ];
  text = ''
    export HELPER_RELEASE_POLICY=${policy}
    exec python3 ${./helper-release.py} "$@"
  '';
  meta = {
    description = "Read-only Nix helper candidates, trusted publication and anonymous verification";
    mainProgram = "helper-release";
    platforms = lib.platforms.unix;
  };
}
