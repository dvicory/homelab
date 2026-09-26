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
      manifest = config.den.aspects.kubernetes.services.media."k8s-manifests" {
        inherit cluster computeResources;
      };
      access = manifest.applications.media-access;
      policy = builtins.head access.objects;
      fixture = pkgs.writeText "media-storage-contract.json" (
        builtins.toJSON {
          script = builtins.elemAt (render fixtureCluster).helm.releases.sabnzbd.values.controllers.main.initContainers.config.command 2;
          removedScript = builtins.elemAt (render cluster).helm.releases.sabnzbd.values.controllers.main.initContainers.config.command 2;
          roots = [
            "/data/library/movies/edition"
            "/data/library/tv/anime"
          ];
          inherit access policy;
          storageWave = manifest.applications.media-storage.annotations."argocd.argoproj.io/sync-wave";
          retainedWave = manifest.applications.sabnzbd-storage.annotations."argocd.argoproj.io/sync-wave";
          workloadWave = (render fixtureCluster).annotations."argocd.argoproj.io/sync-wave";
          hostPath = (render fixtureCluster).helm.releases.sabnzbd.values.persistence.data.hostPath;
          mediaPath = computeResources.mediaPaths.data;
          jellyfinNamespace = cluster.routes.jellyfin.namespace;
          jellyfinPort = cluster.routes.jellyfin.port;
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
            assert contract['access']['namespace'] == contract['jellyfinNamespace']
            policy = contract['policy']
            assert policy['metadata']['namespace'] == contract['jellyfinNamespace']
            assert policy['spec']['podSelector']['matchLabels'] == {
                'app.kubernetes.io/controller': 'main',
                'app.kubernetes.io/instance': 'jellyfin',
                'app.kubernetes.io/name': 'jellyfin',
            }
            assert policy['spec']['ingress'] == [{
                'from': [{
                    'namespaceSelector': {'matchLabels': {'kubernetes.io/metadata.name': 'media'}},
                    'podSelector': {'matchLabels': {
                        'app.kubernetes.io/controller': 'main',
                        'app.kubernetes.io/instance': 'seerr',
                        'app.kubernetes.io/name': 'seerr',
                    }},
                }],
                'ports': [{'protocol': 'TCP', 'port': contract['jellyfinPort']}],
            }]
            assert contract['jellyfinPort'] == 8096
            assert (contract['storageWave'], contract['retainedWave'], contract['workloadWave']) == ('0', '0', '1')
            assert contract['hostPath'] == contract['mediaPath']

            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                data = root / 'data'
                data.mkdir()
                existing = data / 'library/movies/edition'
                existing.mkdir(parents=True)
                existing.chmod(0o750)
                marker = existing / 'movie.mkv'
                marker.write_text('keep media')
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
                assert marker.read_text() == 'keep media'
            PY
            touch "$out"
          '';
    };
}
