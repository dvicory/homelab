{ config, lib, ... }:
let
  serviceName = kind: name: if name == kind then kind else "${kind}-${name}";
  routePrefix =
    route:
    if route == null || route.pathPrefix == "/" then "" else lib.removeSuffix "/" route.pathPrefix;
  secretRef = secretName: key: {
    valueFrom.secretKeyRef = {
      name = secretName;
      inherit key;
    };
  };
  retainedEntry =
    computeResources: key:
    assert lib.assertMsg (builtins.hasAttr key computeResources.retainedPaths)
      "Media state ${key} is not declared in computeResources.retainedPaths.";
    builtins.getAttr key computeResources.retainedPaths;

  mkArr =
    {
      kind,
      port,
      image,
      identity,
    }:
    let
      fleetGroups = config.den.groups or { };
      app = {
        namespace = "media";
        inherit port;
        memory = "1Gi";
      };
      mediaGid = fleetGroups.media.gid;
      dataPathType = lib.types.addCheck lib.types.str (
        path:
        (path == "/data" || lib.hasPrefix "/data/" path)
        && lib.all (part: part != "" && part != ".." && part != ".") (
          builtins.tail (lib.splitString "/" path)
        )
      );
      instanceType = lib.types.submodule (
        { name, ... }:
        {
          options = {
            state = lib.mkOption {
              type = lib.types.strMatching "[a-z0-9]([-a-z0-9]*[a-z0-9])?";
              default = name;
              description = "computeResources.retainedPaths key for this instance's private configuration.";
            };
            routeKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = if name == kind then kind else null;
              description = "Cluster route key for this instance; null keeps it private.";
            };
            apiSecretKey = lib.mkOption {
              type = lib.types.strMatching "[A-Z][A-Z0-9_]*";
              default = "${lib.toUpper kind}_API_KEY";
              description = "Runtime Secret key containing this instance's native API key.";
            };
            role = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum [ "standard" "4k" ]);
              default = if name == kind then "standard" else null;
              description = "Optional Seerr role, independent of the policy bundle. Exactly one standard and at most one 4k instance per kind.";
            };
            root = lib.mkOption {
              type = lib.types.addCheck dataPathType (path: path != "/data");
              default = if kind == "radarr" then "/data/library/movies" else "/data/library/tv";
              description = "Fresh writable library root managed by the native root-folder reconciler.";
            };
            category = lib.mkOption {
              type = lib.types.str;
              default = if kind == "radarr" then "movies" else "tv";
              description = "Fresh download category assigned to this instance.";
            };
            bundle = lib.mkOption {
              type = lib.types.enum [
                "web-1080p"
                "web-2160p"
              ];
              default = "web-1080p";
              description = "Semantic pinned media policy bundle applied to this instance.";
            };
            sharedWritablePaths = lib.mkOption {
              type = lib.types.listOf dataPathType;
              default = [ ];
              description = "Grant /data for the shared mount. Overlapping library roots additionally require both instances to grant a common containing path below /data.";
            };
          };
        }
      );
      routeFor =
        {
          cluster,
          instanceName,
          cfg,
        }:
        let
          routeKey = cfg.routeKey;
          expected = {
            namespace = app.namespace;
            service = serviceName kind instanceName;
            inherit port;
          };
        in
        if routeKey == null then
          null
        else
          assert lib.assertMsg (builtins.hasAttr routeKey cluster.routes)
            "Media instance ${kind}/${instanceName} references missing route ${routeKey}.";
          let
            route = builtins.getAttr routeKey cluster.routes;
          in
          assert lib.assertMsg
            (
              route.namespace == expected.namespace
              && route.service == expected.service
              && route.port == expected.port
            )
            "Media route ${routeKey} must target ${expected.namespace}/${expected.service}:${toString expected.port}.";
          route;
      mkArrValues =
        {
          cluster,
          computeResources,
          kind,
          instanceName,
          cfg,
        }:
        let
          state = retainedEntry computeResources cfg.state;
          route = routeFor { inherit cluster instanceName cfg; };
          prefix = routePrefix route;
          service = serviceName kind instanceName;
          secretName = cluster.settings.kubernetes.services.media.configurationSecret;
          apiKeyEnv = "${lib.toUpper kind}__AUTH__APIKEY";
        in
        assert lib.assertMsg (!state.readOnly) "Media state ${cfg.state} must be writable.";
        assert lib.assertMsg (lib.elem "/data" cfg.sharedWritablePaths)
          "Media instance ${kind}/${instanceName} must explicitly declare shared writable path /data.";
        {
          fullnameOverride = service;
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
              inherit image;
              env = {
                TZ = "UTC";
                PUID = toString identity.uid;
                PGID = toString identity.gid;
                UMASK = "007";
                "${apiKeyEnv}" = secretRef secretName cfg.apiSecretKey;
                "${lib.toUpper kind}__SERVER__URLBASE" = prefix;
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
              probes = lib.genAttrs [ "startup" "readiness" "liveness" ] (probe: {
                enabled = true;
                custom = true;
                spec = {
                  httpGet = {
                    path = "${prefix}/ping";
                    port = app.port;
                  };
                  periodSeconds = 10;
                  timeoutSeconds = 5;
                  failureThreshold = if probe == "startup" then 60 else 6;
                };
              });
            };
          };
          service.main = {
            controller = "main";
            ports.http.port = app.port;
          };
          persistence = {
            config = {
              type = "persistentVolumeClaim";
              existingClaim = "media-${cfg.state}";
              globalMounts = [ { path = "/config"; } ];
            };
            data = {
              type = "hostPath";
              hostPath = computeResources.mediaPaths.data;
              hostPathType = "Directory";
              globalMounts = [ { path = "/data"; } ];
            };
          };
        };
      mkArrApplications =
        {
          cluster,
          computeResources,
          charts,
        }:
        let
          instances = cluster.settings.kubernetes.services.media.${kind};
        in
        lib.mapAttrs' (
          instanceName: cfg:
          lib.nameValuePair (serviceName kind instanceName) {
            namespace = app.namespace;
            annotations."argocd.argoproj.io/sync-wave" = "1";
            helm.releases.${serviceName kind instanceName} = {
              chart = charts.bjw-s-labs.app-template;
              values = mkArrValues {
                inherit
                  cluster
                  computeResources
                  kind
                  instanceName
                  cfg
                  ;
              };
            };
          }
        ) instances;
    in
    {
      option = lib.mkOption {
        type = lib.types.attrsOf instanceType;
        default = {
          ${kind} = { };
        };
        description = "Independent ${kind} instances and their state, routes and policy.";
      };
      aspect = {
        compute-resources =
          { cluster, ... }:
          let
            settings = cluster.settings.kubernetes.services.media;
          in
          {
            retainedPaths = lib.mapAttrs' (
              _: cfg:
              lib.nameValuePair cfg.state {
                inherit (identity) uid gid;
                mode = "0700";
              }
            ) settings.${kind};
            runtimeSecrets = lib.listToAttrs (
              map (cfg: {
                name = "media--${settings.configurationSecret}--${cfg.apiSecretKey}";
                value = {
                  namespace = "media";
                  name = settings.configurationSecret;
                  key = cfg.apiSecretKey;
                  generator = "api-key";
                };
              }) (builtins.attrValues settings.${kind})
            );
          };
        k8s-manifests =
          {
            cluster,
            computeResources,
            charts,
            ...
          }:
          let
            settings = cluster.settings.kubernetes.services.media;
          in
          {
            config.applications = mkArrApplications { inherit cluster computeResources charts; };
          };
      };
    };
  radarr = mkArr {
    kind = "radarr";
    port = 7878;
    # Container IDs coincide with host service-account numbers by convention only.
    identity = {
      uid = 752;
      gid = 752;
    };
    image = {
      repository = "ghcr.io/linuxserver/radarr";
      tag = "6.3.0.10514-ls315";
      digest = "sha256:95ba0801df4d9d1d79d0d9a3849f656542497dab061d91b87ad4f53a71aff3ef";
    };
  };
  sonarr = mkArr {
    kind = "sonarr";
    port = 8989;
    # Container IDs coincide with host service-account numbers by convention only.
    identity = {
      uid = 753;
      gid = 753;
    };
    image = {
      repository = "ghcr.io/linuxserver/sonarr";
      tag = "4.0.19.2979-ls323";
      digest = "sha256:4d9df314875e1249ab7d6170c2b9b3dc1d8e6383f168ceb10dc9a5ad9b324739";
    };
  };
in
{
  den.aspects.kubernetes.services.media = {
    settings = {
      radarr = radarr.option;
      sonarr = sonarr.option;
    };
    arr.provides = {
      radarr = radarr.aspect;
      sonarr = sonarr.aspect;
    };
  };
}
