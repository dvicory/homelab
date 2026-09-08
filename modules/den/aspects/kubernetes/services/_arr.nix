{
  kind,
  port,
  uid,
  image,
}:
{ lib, ... }:
let
  apps.${kind} = {
    namespace = "media";
    inherit port;
    memory = "1Gi";
  };
  images.${kind} = image;
  inherit (lib) mkOption types;
  inherit (import ./_media-lib.nix { inherit lib; })
    retainedEntry
    routePrefix
    secretRef
    mkStorage
    serviceName
    ;

  instanceType =
    kind:
    types.submodule (
      { name, ... }: {
        options = {
          state = mkOption {
            type = types.strMatching "[a-z0-9]([-a-z0-9]*[a-z0-9])?";
            default = name;
            description = "compute.retainedPaths key for this instance's private configuration.";
          };
          routeKey = mkOption {
            type = types.nullOr types.str;
            default = if name == kind then kind else null;
            description = "Cluster route key for this instance; null keeps it private.";
          };
          apiSecretKey = mkOption {
            type = types.strMatching "[A-Z][A-Z0-9_]*";
            default = "${lib.toUpper kind}_API_KEY";
            description = "Runtime Secret key containing this instance's native API key.";
          };
          root = mkOption {
            type = types.addCheck types.str (
              path:
              lib.hasPrefix "/data/" path
              && path != "/data/"
              && lib.all (part: part != ".." && part != ".") (lib.splitString "/" path)
            );
            default = if kind == "radarr" then "/data/movies" else "/data/tv";
            description = "Fresh writable library root managed by the native root-folder reconciler.";
          };
          category = mkOption {
            type = types.str;
            default = if kind == "radarr" then "movies" else "tv";
            description = "Fresh download category assigned to this instance.";
          };
          profile = mkOption {
            type = types.enum [
              "WEB-1080p"
              "WEB-2160p"
            ];
            default = "WEB-1080p";
            description = "Selected configuration profile name.";
          };
        };
      }
    );

  routeFor =
    {
      cluster,
      kind,
      instanceName,
      cfg,
    }:
    let
      routeKey = cfg.routeKey;
      expected = {
        namespace = apps.${kind}.namespace;
        service = serviceName kind instanceName;
        port = apps.${kind}.port;
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
      compute,
      charts,
      kind,
      instanceName,
      cfg,
    }:
    let
      app = apps.${kind};
      state = retainedEntry compute cfg.state;
      data = retainedEntry compute "media-data";
      route = routeFor {
        inherit
          cluster
          kind
          instanceName
          cfg
          ;
      };
      prefix = routePrefix route;
      service = serviceName kind instanceName;
      secretName = cluster.settings.kubernetes.services.media.configurationSecret;
      apiKeyEnv = "${lib.toUpper kind}__AUTH__APIKEY";
    in
    assert lib.assertMsg (!state.readOnly) "Media state ${cfg.state} must be writable.";
    {
      fullnameOverride = service;
      defaultPodOptions = {
        nodeSelector."kubernetes.io/hostname" = compute.instance;
        automountServiceAccountToken = false;
      };
      controllers.main = {
        type = "deployment";
        strategy = "Recreate";
        replicas = 1;
        containers.main = {
          image = images.${kind};
          env = {
            TZ = "UTC";
            PUID = toString state.uid;
            PGID = toString data.gid;
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
        # media-data is an explicitly shared fresh download/library boundary;
        # each instance keeps its private database on its own retained claim.
        data = {
          type = "persistentVolumeClaim";
          existingClaim = "media-data";
          globalMounts = [ { path = "/data"; } ];
        };
      };
    };

  mkArrApplications =
    kind:
    {
      cluster,
      compute,
      charts,
    }:
    let
      instances = cluster.settings.kubernetes.services.media.${kind};
    in
    lib.mapAttrs' (
      instanceName: cfg:
      lib.nameValuePair (serviceName kind instanceName) {
        namespace = apps.${kind}.namespace;
        helm.releases.${serviceName kind instanceName} = {
          chart = charts.bjw-s-labs.app-template;
          values = mkArrValues {
            inherit
              cluster
              compute
              charts
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
  den.aspects.kubernetes.services.media.settings.${kind} = mkOption {
    type = types.attrsOf (instanceType kind);
    default = {
      ${kind} = { };
    };
    description = "Independent ${kind} instances and their state, routes and policy.";
  };
  den.aspects.kubernetes.services.${kind} = {
    compute-resources =
      { cluster, config, ... }:
      let
        settings = cluster.settings.kubernetes.services.media;
      in
      {
        retainedPaths = lib.mapAttrs' (
          _: cfg:
          lib.nameValuePair cfg.state {
            inherit uid;
            gid = config.retainedPaths.media-data.gid;
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
            };
          }) (builtins.attrValues settings.${kind})
        );
      };
    k8s-manifests =
      {
        cluster,
        compute,
        charts,
        ...
      }:
      {
        applications = mkArrApplications kind { inherit cluster compute charts; } // {
          "${kind}-storage" = {
            namespace = "media";
            objects = lib.concatMap (cfg: mkStorage compute cfg.state "5Gi") (
              builtins.attrValues cluster.settings.kubernetes.services.media.${kind}
            );
          };
        };
      };
  };
}
