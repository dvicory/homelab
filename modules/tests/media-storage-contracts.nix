{
  config,
  inputs,
  lib,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      cluster = config.den.clusters.prod-home;
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      computeResources = {
        inherit (compute) instance retainedPaths;
        inherit (config.flake.clusterResources.prod-home) mediaPaths;
      };
      charts = inputs.nixhelm.chartsDerivations.${system};
      fixtureCluster = cluster // {
        settings = lib.recursiveUpdate cluster.settings {
          kubernetes.services.media = {
            radarr.radarr.root = "/data/library/movies/edition";
            sonarr.sonarr.root = "/data/library/tv/anime";
          };
        };
      };
      sab = config.den.aspects.kubernetes.services.sabnzbd."k8s-manifests";
      render =
        declared:
        (sab {
          cluster = declared;
          inherit computeResources charts;
        }).applications.sabnzbd;
      fixture = pkgs.writeText "media-storage-contract.json" (
        builtins.toJSON {
          script = builtins.elemAt (render fixtureCluster).helm.releases.sabnzbd.values.controllers.main.initContainers.config.command 2;
          removedScript = builtins.elemAt (render cluster).helm.releases.sabnzbd.values.controllers.main.initContainers.config.command 2;
          roots = [
            "/data/library/movies/edition"
            "/data/library/tv/anime"
          ];
        }
      );
    in
    {
      checks.media-storage-contracts =
        pkgs.runCommand "media-storage-contracts"
          {
            nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.configobj ])) ];
          }
          ''
            python - ${fixture} <<'PY'
            import json
            import os
            from pathlib import Path
            import stat
            import sys
            import tempfile

            contract = json.loads(Path(sys.argv[1]).read_text())

            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                data = root / 'data'
                data.mkdir()
                existing = data / 'library/movies/edition'
                existing.mkdir(parents=True)
                existing.chmod(0o750)
                media_file = existing / 'operator-owned-media'
                media_file.write_bytes(b'preserved across root declaration removal')
                config_path = root / 'sabnzbd.ini'
                values = {
                    'SABNZBD_API_KEY': 'fixture-key',
                    'SABNZBD_USERNAME': 'fixture-user',
                    'SABNZBD_PASSWORD': 'fixture-password',
                }
                before = os.environ.copy()
                os.environ.update(values)
                try:
                    for script in (contract['script'], contract['removedScript']):
                        translated = script.replace("path = '/config/sabnzbd.ini'", f'path = {str(config_path)!r}').replace('/data', str(data))
                        exec(compile(translated, '<sabnzbd-init>', 'exec'), {'__name__': '__main__'})
                finally:
                    os.environ.clear()
                    os.environ.update(before)
                assert all((data / path.removeprefix('/data/')).is_dir() for path in contract['roots'])
                assert (data / 'downloads/usenet/incomplete').is_dir()
                assert (data / 'downloads/usenet/complete').is_dir()
                assert stat.S_IMODE(existing.stat().st_mode) == 0o750
                assert media_file.read_bytes() == b'preserved across root declaration removal'
            PY
            touch "$out"
          '';
    };
}
