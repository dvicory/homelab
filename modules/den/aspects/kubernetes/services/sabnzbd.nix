{ config, lib, ... }:
let
  fleetGroups = config.den.groups or { };
  # Container IDs coincide with host service-account numbers by convention only.
  identity = {
    uid = 757;
    gid = 757;
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
  retainedEntry =
    computeResources: key:
    assert lib.assertMsg (builtins.hasAttr key computeResources.retainedPaths)
      "Media state ${key} is not declared in computeResources.retainedPaths.";
    builtins.getAttr key computeResources.retainedPaths;
  routePrefix = route: if route.pathPrefix == "/" then "" else lib.removeSuffix "/" route.pathPrefix;
  fixedRoute =
    {
      cluster,
      name,
      app,
    }:
    assert lib.assertMsg (builtins.hasAttr name cluster.routes) "Media route ${name} is not declared.";
    let
      route = builtins.getAttr name cluster.routes;
    in
    assert lib.assertMsg (
      route.namespace == app.namespace && route.service == app.service && route.port == app.port
    ) "Media route ${name} must target ${app.namespace}/${app.service}:${toString app.port}.";
    route;
  secretRef = secretName: key: {
    valueFrom.secretKeyRef = {
      name = secretName;
      inherit key;
    };
  };
  mediaGid = fleetGroups.media.gid;
  inherit (lib) mkOption types;
  ownSecretKeys = [
    "SABNZBD_API_KEY"
    "SABNZBD_USERNAME"
    "SABNZBD_PASSWORD"
  ];
  providerEnvName = name: lib.toUpper (builtins.replaceStrings [ "-" "." ] [ "_" "_" ] name);
  providerSecretKeys =
    providers:
    lib.concatMap (
      name:
      let
        envName = providerEnvName name;
      in
      [
        "USENET_${envName}_USERNAME"
        "USENET_${envName}_PASSWORD"
      ]
    ) (builtins.attrNames providers);
  providerType = types.submodule {
    options = {
      host = mkOption {
        type = types.strMatching "[a-zA-Z0-9]([-a-zA-Z0-9.]*[a-zA-Z0-9])?";
        description = "Usenet server hostname.";
      };
      port = mkOption {
        type = types.port;
        default = 563;
        description = "Usenet server port.";
      };
      ssl = mkOption {
        type = types.bool;
        default = true;
        description = "Whether SABnzbd connects with TLS.";
      };
      connections = mkOption {
        type = types.ints.between 1 100;
        description = "Maximum concurrent connections SABnzbd opens to this server.";
      };
      priority = mkOption {
        type = types.ints.between 0 99;
        default = 0;
        description = "SABnzbd server priority; 0 is the primary tier.";
      };
    };
  };
  checkedProviders =
    providers:
    let
      names = builtins.attrNames providers;
      keys = providerSecretKeys providers;
    in
    assert lib.assertMsg (lib.all (
      name: builtins.match "[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?" name != null
    ) names) "SABnzbd provider names must contain only letters, numbers, '.', '-' or '_'.";
    assert lib.assertMsg (
      lib.unique keys == keys
    ) "SABnzbd provider names must not collide after runtime Secret key normalization.";
    providers;
in
{
  den.aspects.kubernetes.services.media.settings.sabnzbd = mkOption {
    type = types.submodule {
      options.providers = mkOption {
        type = types.attrsOf providerType;
        default = { };
        description = ''
          Usenet servers written to SABnzbd's [servers] section by the config
          init container. Provider credentials are separate runtime Secret keys
          derived from provider names; the operator supplies their values with
          agenix.
        '';
      };
    };
    default = { };
    description = "SABnzbd-specific declarative configuration.";
  };
  den.aspects.kubernetes.services.sabnzbd.compute-resources =
    { cluster, ... }:
    let
      settings = cluster.settings.kubernetes.services.media;
      providers = checkedProviders settings.sabnzbd.providers;
      generators = {
        SABNZBD_API_KEY = "api-key";
        SABNZBD_PASSWORD = "alnum-no-newline";
      };
    in
    {
      # LinuxServer PUID/PGID are guest-local; media is a supplemental capability.
      retainedPaths.sabnzbd = {
        inherit (identity) uid gid;
        mode = "0700";
      };
      runtimeSecrets = lib.listToAttrs (
        map (key: {
          name = "media--${settings.configurationSecret}--${key}";
          value = {
            namespace = "media";
            name = settings.configurationSecret;
            inherit key;
            generator = generators.${key} or null;
          };
        }) (ownSecretKeys ++ providerSecretKeys providers)
      );
    };
  den.aspects.kubernetes.services.sabnzbd.k8s-manifests =
    {
      cluster,
      computeResources,
      charts,
      ...
    }:
    let
      app = apps.sabnzbd;
      state = retainedEntry computeResources "sabnzbd";
      route = fixedRoute {
        cluster = cluster;
        name = "sabnzbd";
        inherit app;
      };
      secretName = cluster.settings.kubernetes.services.media.configurationSecret;
      providers = checkedProviders cluster.settings.kubernetes.services.media.sabnzbd.providers;
      requiredKeys = ownSecretKeys ++ providerSecretKeys providers;
      downloadCategories = lib.unique (
        map (cfg: cfg.category) (
          builtins.attrValues cluster.settings.kubernetes.services.media.radarr
          ++ builtins.attrValues cluster.settings.kubernetes.services.media.sonarr
        )
      );
      sabConfig = ''
        import json
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
        for key in ${builtins.toJSON requiredKeys}:
            if not os.environ[key].strip():
                raise ValueError('Required runtime secret is empty: ' + key)
        for directory in ('library/movies', 'library/tv', 'downloads/usenet/incomplete', 'downloads/usenet/complete'):
            os.makedirs('/data/' + directory, mode=0o2770, exist_ok=True)
        categories = config.setdefault('categories', {})
        for name in ${builtins.toJSON downloadCategories}:
            category = categories.setdefault(name, {})
            category.update({
                'name': name, 'order': '0', 'priority': '-100', 'pp': '3',
                'script': 'Default', 'dir': name, 'newzbin': "",
            })
        providers = json.loads(${builtins.toJSON (builtins.toJSON providers)})
        managed = 'managed-by: homelab'
        servers = config.setdefault('servers', {})
        for name, provider in providers.items():
            env_name = name.replace('-', '_').replace('.', '_').upper()
            username_key = 'USENET_' + env_name + '_USERNAME'
            password_key = 'USENET_' + env_name + '_PASSWORD'
            server = servers.setdefault(name, {})
            server.setdefault('displayname', name)
            server.update({
                'host': provider['host'], 'port': str(provider['port']),
                'ssl': '1' if provider['ssl'] else '0',
                'connections': str(provider['connections']),
                'priority': str(provider['priority']),
                'username': os.environ[username_key],
                'password': os.environ[password_key],
                'enable': '1', 'notes': managed,
            })
        for name in list(servers):
            if name not in providers and servers[name].get('notes') == managed:
                del servers[name]
        config.filename = path + '.tmp'
        config.write()
        os.chmod(config.filename, 0o600)
        os.replace(config.filename, path)
      '';
    in
    {
      applications.sabnzbd = {
        namespace = app.namespace;
        helm.releases.sabnzbd = {
          chart = charts.bjw-s-labs.app-template;
          values = {
            fullnameOverride = "sabnzbd";
            defaultPodOptions = {
              nodeSelector."kubernetes.io/hostname" = computeResources.instance;
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
                env = lib.genAttrs requiredKeys (secretRef secretName);
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
                hostPath = "/srv/media/data";
                hostPathType = "Directory";
                globalMounts = [ { path = "/data"; } ];
              };
            };
          };
        };
      };
    };
}
