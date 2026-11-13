{
  lib,
  runCommand,
  makeWrapper,
  python3,
  gh,
  nix,
}:
runCommand "dependency-track-sync"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta = {
      description = "Import sealed Homelab inventories into stock private Dependency-Track";
      mainProgram = "dependency-track-sync";
      platforms = lib.platforms.unix;
    };
    passthru.tests = runCommand "dependency-track-sync-tests" { nativeBuildInputs = [ python3 ]; } ''
      cp ${./dependency_track_sync.py} dependency_track_sync.py
      cp ${./homelab_origins.py} homelab_origins.py
      cp ${./homelab_origin_bom.py} homelab_origin_bom.py
      cp ${./homelab-origins.nix} homelab-origins.nix
      cp ${../../../.github/security_artifacts.py} security_artifacts.py
      cp ${./test.py} test.py
      cp ${./advisory-policy.json} advisory-policy.json
      python3 -B test.py
      touch $out
    '';
  }
  ''
    mkdir -p $out/bin $out/lib/dependency-track-sync
    cp ${./dependency_track_sync.py} $out/lib/dependency-track-sync/dependency_track_sync.py
    cp ${./homelab_origins.py} $out/lib/dependency-track-sync/homelab_origins.py
    cp ${./homelab_origin_bom.py} $out/lib/dependency-track-sync/homelab_origin_bom.py
    cp ${./homelab-origins.nix} $out/lib/dependency-track-sync/homelab-origins.nix
    cp ${../../../.github/security_artifacts.py} $out/lib/dependency-track-sync/security_artifacts.py
    cp ${./advisory-policy.json} $out/lib/dependency-track-sync/advisory-policy.json
    makeWrapper ${lib.getExe python3} $out/bin/dependency-track-sync \
      --add-flags "-B $out/lib/dependency-track-sync/dependency_track_sync.py" \
      --prefix PATH : ${
        lib.makeBinPath [
          gh
          nix
        ]
      }
  ''
