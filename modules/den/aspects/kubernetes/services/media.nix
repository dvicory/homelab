{
  den.aspects.kubernetes.services.media.k8s-manifests =
    { lib, charts, cluster, ... }:
    let
      routes = cluster.routes;
      prefix = name: if routes.${name}.pathPrefix == "/" then "" else routes.${name}.pathPrefix;
      url = name: "https://${builtins.head routes.${name}.hostnames}${prefix name}";
      retained = { "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false"; };
      secret = key: { valueFrom.secretKeyRef = { name = "media-runtime"; inherit key; }; };
      images = {
        radarr = { repository = "ghcr.io/linuxserver/radarr"; tag = "latest"; digest = "sha256:95ba0801df4d9d1d79d0d9a3849f656542497dab061d91b87ad4f53a71aff3ef"; };
        sonarr = { repository = "ghcr.io/linuxserver/sonarr"; tag = "latest"; digest = "sha256:4d9df314875e1249ab7d6170c2b9b3dc1d8e6383f168ceb10dc9a5ad9b324739"; };
        sabnzbd = { repository = "ghcr.io/linuxserver/sabnzbd"; tag = "latest"; digest = "sha256:64c4c2b6ed546237451cbfec33aa8bac1396865c1a266dd247c02b36ffe27c62"; };
        seerr = { repository = "ghcr.io/seerr-team/seerr"; tag = "v3.4.1"; digest = "sha256:f4768de5f616248d723e05891f3345a1402123775d03bf0890dbfedc0831bda1"; };
      };
      apps = {
        radarr = { uid = 752; port = 7878; memory = "1Gi"; };
        sonarr = { uid = 753; port = 8989; memory = "1Gi"; };
        sabnzbd = { uid = 754; port = 8080; memory = "2Gi"; };
        seerr = { uid = 1000; port = 5055; memory = "1Gi"; };
      };
      volumes = { radarr = "5Gi"; sonarr = "5Gi"; sabnzbd = "5Gi"; seerr = "5Gi"; data = "100Gi"; };
      # ConfigObj is SAB's own INI parser: nested categories and unrelated provider
      # settings survive reconciliation. No provider credentials are provisioned.
      sabConfig = ''
        import os
        from configobj import ConfigObj
        os.umask(0o007)
        path = '/config/sabnzbd.ini'
        config = ConfigObj(path, encoding='utf-8')
        misc = config.setdefault('misc', {})
        misc.update({
            'host': '0.0.0.0', 'port': '8080',
            'api_key': os.environ['SABNZBD_API_KEY'],
            'username': os.environ['SABNZBD_USERNAME'],
            'password': os.environ['SABNZBD_PASSWORD'],
            'host_whitelist': ${builtins.toJSON (lib.concatStringsSep ", " (routes.sabnzbd.hostnames ++ [ "sabnzbd" "sabnzbd.media.svc" ]))},
            'inet_exposure': '4', 'permissions': '770',
            'download_dir': '/data/usenet/incomplete',
            'complete_dir': '/data/usenet/complete',
        })
        for key in ('SABNZBD_API_KEY', 'SABNZBD_USERNAME', 'SABNZBD_PASSWORD'):
            if not os.environ[key].strip():
                raise ValueError('Required runtime secret is empty: ' + key)
        for directory in ('usenet/incomplete', 'usenet/complete', 'movies', 'tv'):
            os.makedirs('/data/' + directory, mode=0o2770, exist_ok=True)
        categories = config.setdefault('categories', {})
        for name in ('movies', 'tv'):
            categories.setdefault(name, {'name': name, 'order': '0', 'priority': '-100', 'pp': '3', 'script': 'Default', 'dir': name, 'newzbin': ""})
        config.filename = path + '.tmp'
        config.write()
        os.chmod(config.filename, 0o600)
        os.replace(config.filename, path)
      '';
    in
    assert lib.assertMsg (routes.sabnzbd.pathPrefix == "/" && routes.requests.pathPrefix == "/") "SABnzbd and Seerr require hostname-root routes";
    let
      storage = name: size: [
        {
          apiVersion = "v1";
          kind = "PersistentVolume";
          metadata = { name = "media-${name}"; annotations = retained; };
          spec = {
            capacity.storage = size;
            volumeMode = "Filesystem";
            accessModes = [ "ReadWriteOnce" ];
            persistentVolumeReclaimPolicy = "Retain";
            storageClassName = "";
            local.path = "${cluster.storageRoot}/media/${name}";
            claimRef = { namespace = "media"; name = "media-${name}"; };
            nodeAffinity.required.nodeSelectorTerms = [ {
              matchExpressions = [ {
                key = "kubernetes.io/hostname";
                operator = "In";
                values = [ cluster.nodeName ];
              } ];
            } ];
          };
        }
        {
          apiVersion = "v1";
          kind = "PersistentVolumeClaim";
          metadata = { name = "media-${name}"; namespace = "media"; annotations = retained; };
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            storageClassName = "";
            volumeName = "media-${name}";
            resources.requests.storage = size;
          };
        }
      ];
    in
    {
      applications = {
        media-state = {
          namespace = "media";
          objects = [
            {
              apiVersion = "v1";
              kind = "Namespace";
              metadata = { name = "media"; annotations = retained; };
            }
          ] ++ lib.concatLists (lib.mapAttrsToList storage volumes);
        };
      } // lib.mapAttrs (name: app: {
        namespace = "media";
        helm.releases.${name} = {
          chart = charts.bjw-s-labs.app-template;
          values = {
            fullnameOverride = name;
            defaultPodOptions = {
              nodeSelector."kubernetes.io/hostname" = cluster.nodeName;
              automountServiceAccountToken = false;
            };
            controllers.main = {
              type = if name == "seerr" then "statefulset" else "deployment";
              strategy = if name == "seerr" then "RollingUpdate" else "Recreate";
              replicas = 1;
              containers.main = {
                image = images.${name};
                env = { TZ = "UTC"; } // (if name == "seerr" then {} else {
                  PUID = toString app.uid; PGID = "751"; UMASK = "007";
                }) // lib.optionalAttrs (name == "radarr" || name == "sonarr") {
                  "${lib.toUpper name}__AUTH__APIKEY" = secret "${lib.toUpper name}_API_KEY";
                  "${lib.toUpper name}__SERVER__URLBASE" = prefix name;
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  seccompProfile.type = "RuntimeDefault";
                } // lib.optionalAttrs (name == "seerr") {
                  capabilities.drop = [ "ALL" ];
                  runAsUser = 1000; runAsGroup = 1000; runAsNonRoot = true;
                };
                resources = { requests = { cpu = "100m"; memory = "256Mi"; }; limits = { cpu = "2"; memory = app.memory; }; };
                probes = lib.genAttrs [ "startup" "readiness" "liveness" ] (probe: {
                  enabled = true;
                  type = if name == "sabnzbd" then "TCP" else "HTTP";
                  port = app.port;
                  custom = true;
                  spec = (if name == "sabnzbd" then { tcpSocket.port = app.port; } else {
                    httpGet = { port = app.port; path = if name == "seerr" then "/api/v1/status" else "${prefix name}/ping"; };
                  }) // { periodSeconds = 10; timeoutSeconds = 5; failureThreshold = if probe == "startup" then 60 else 6; };
                });
              };
              initContainers = lib.optionalAttrs (name == "sabnzbd") {
                config = {
                  image = images.sabnzbd;
                  command = [ "/lsiopy/bin/python" "-c" sabConfig ];
                  env = lib.genAttrs [ "SABNZBD_API_KEY" "SABNZBD_USERNAME" "SABNZBD_PASSWORD" ] secret;
                  securityContext = {
                    runAsUser = 754; runAsGroup = 751; runAsNonRoot = true;
                    allowPrivilegeEscalation = false; capabilities.drop = [ "ALL" ]; seccompProfile.type = "RuntimeDefault";
                  };
                  resources = { requests = { cpu = "10m"; memory = "32Mi"; }; limits = { cpu = "250m"; memory = "128Mi"; }; };
                };
              };
            };
            service.main = { controller = "main"; ports.http.port = app.port; };
            persistence = {
              config = { type = "persistentVolumeClaim"; existingClaim = "media-${name}"; globalMounts = [{ path = if name == "seerr" then "/app/config" else "/config"; }]; };
            } // lib.optionalAttrs (name != "seerr") {
              data = { type = "persistentVolumeClaim"; existingClaim = "media-data"; globalMounts = [{ path = "/data"; }]; };
            };
          };
        };
      }) apps;
    };
}
