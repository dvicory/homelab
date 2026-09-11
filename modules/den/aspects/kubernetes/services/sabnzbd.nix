{ config, lib, ... }:
let
  fleetGroups = config.den.groups or { };
  # Container IDs coincide with host service-account numbers by convention only.
  identity = {
    uid = 754;
    gid = 754;
  };
  apps.sabnzbd = {
    namespace = "media";
    service = "sabnzbd";
    port = 8080;
    memory = "2Gi";
  };
  images.sabnzbd = {
    repository = "ghcr.io/linuxserver/sabnzbd";
    tag = "latest";
    digest = "sha256:64c4c2b6ed546237451cbfec33aa8bac1396865c1a266dd247c02b36ffe27c62";
  };
  inherit (import ./_media-lib.nix { inherit lib; })
    retainedEntry
    fixedRoute
    secretRef
    mkStorage
    ;
  mediaGid = fleetGroups.media.gid;
in
{
  den.aspects.kubernetes.services.sabnzbd.compute-resources = { cluster, ... }: {
    # LinuxServer PUID/PGID are guest-local; media is a supplemental capability.
    retainedPaths.sabnzbd = {
      inherit (identity) uid gid;
      mode = "0700";
    };
    runtimeSecrets = lib.listToAttrs (
      map
        (key: {
          name = "media--${cluster.settings.kubernetes.services.media.configurationSecret}--${key}";
          value = {
            namespace = "media";
            name = cluster.settings.kubernetes.services.media.configurationSecret;
            inherit key;
          };
        })
        [
          "SABNZBD_API_KEY"
          "SABNZBD_USERNAME"
          "SABNZBD_PASSWORD"
        ]
    );
  };
  den.aspects.kubernetes.services.sabnzbd.k8s-manifests =
    {
      cluster,
      compute,
      charts,
      ...
    }:
    let
      app = apps.sabnzbd;
      state = retainedEntry compute "sabnzbd";
      route = fixedRoute {
        cluster = cluster;
        name = "sabnzbd";
        inherit app;
      };
      secretName = cluster.settings.kubernetes.services.media.configurationSecret;
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
            'host_whitelist': ${
              builtins.toJSON (
                lib.concatStringsSep ", " (
                  route.hostnames
                  ++ [
                    "sabnzbd"
                    "sabnzbd.media.svc"
                  ]
                )
              )
            },
            'inet_exposure': '4', 'permissions': '770',
            'download_dir': '/data/downloads/usenet/incomplete',
            'complete_dir': '/data/downloads/usenet/complete',
        })
        for key in ('SABNZBD_API_KEY', 'SABNZBD_USERNAME', 'SABNZBD_PASSWORD'):
            if not os.environ[key].strip():
                raise ValueError('Required runtime secret is empty: ' + key)
        for directory in ('library/movies', 'library/tv', 'downloads/usenet/incomplete', 'downloads/usenet/complete'):
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
    {
      applications.sabnzbd-storage = {
        namespace = app.namespace;
        objects = mkStorage compute "sabnzbd" "5Gi";
      };
      applications.sabnzbd = {
        namespace = app.namespace;
        helm.releases.sabnzbd = {
          chart = charts.bjw-s-labs.app-template;
          values = {
            fullnameOverride = "sabnzbd";
            defaultPodOptions = {
              nodeSelector."kubernetes.io/hostname" = compute.instance;
              automountServiceAccountToken = false;
              securityContext.supplementalGroups = [ mediaGid ];
            };
            controllers.main = {
              type = "deployment";
              strategy = "Recreate";
              replicas = 1;
              containers.main = {
                image = images.sabnzbd;
                env = {
                  TZ = "UTC";
                  PUID = toString identity.uid;
                  PGID = toString identity.gid;
                  UMASK = "007";
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  seccompProfile.type = "RuntimeDefault";
                };
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "256Mi";
                  };
                  limits = {
                    cpu = "2";
                    memory = app.memory;
                  };
                };
                probes = {
                  startup = {
                    enabled = true;
                    custom = true;
                    spec = {
                      tcpSocket.port = app.port;
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = 60;
                    };
                  };
                  readiness = {
                    enabled = true;
                    custom = true;
                    spec = {
                      tcpSocket.port = app.port;
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                    };
                  };
                  liveness = {
                    enabled = true;
                    custom = true;
                    spec = {
                      tcpSocket.port = app.port;
                      periodSeconds = 30;
                      timeoutSeconds = 5;
                    };
                  };
                };
              };
              initContainers.config = {
                image = images.sabnzbd;
                command = [
                  "/lsiopy/bin/python"
                  "-c"
                  sabConfig
                ];
                env = {
                  SABNZBD_API_KEY = secretRef secretName "SABNZBD_API_KEY";
                  SABNZBD_USERNAME = secretRef secretName "SABNZBD_USERNAME";
                  SABNZBD_PASSWORD = secretRef secretName "SABNZBD_PASSWORD";
                };
                securityContext = {
                  runAsUser = identity.uid;
                  runAsGroup = identity.gid;
                  runAsNonRoot = true;
                  allowPrivilegeEscalation = false;
                  capabilities.drop = [ "ALL" ];
                  seccompProfile.type = "RuntimeDefault";
                };
                resources = {
                  requests = {
                    cpu = "10m";
                    memory = "32Mi";
                  };
                  limits = {
                    cpu = "250m";
                    memory = "128Mi";
                  };
                };
              };
            };
            service.main = {
              controller = "main";
              ports.http.port = app.port;
            };
            persistence = {
              config = {
                type = "persistentVolumeClaim";
                existingClaim = "media-sabnzbd";
                globalMounts = [ { path = "/config"; } ];
              };
              data = {
                type = "hostPath";
                hostPath = "/srv/media";
                hostPathType = "Directory";
                globalMounts = [ { path = "/data"; } ];
              };
            };
          };
        };
      };
    };
}
