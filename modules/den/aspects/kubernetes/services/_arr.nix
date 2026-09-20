{
  application,
}:
{ config, lib, ... }:
let
  fleetGroups = config.den.groups or { };
  inherit (application)
    kind
    port
    image
    identity
    defaultRoot
    defaultCategory
    profiles
    ;
  app = {
    namespace = "media";
    inherit port;
    memory = "1Gi";
  };
  inherit (lib) mkOption types;
  inherit (import ./_media-lib.nix { inherit lib; })
    retainedEntry
    routePrefix
    secretRef
    mkStorage
    serviceName
    ;
  mediaGid = fleetGroups.media.gid;

  dataPathType = types.addCheck types.str (
    path:
    (path == "/data" || lib.hasPrefix "/data/" path)
    && lib.all (part: part != "" && part != ".." && part != ".") (
      builtins.tail (lib.splitString "/" path)
    )
  );

  instanceType = types.submodule (
    { name, ... }:
    {
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
          type = types.addCheck dataPathType (path: path != "/data");
          default = defaultRoot;
          description = "Fresh writable library root managed by the native root-folder reconciler.";
        };
        category = mkOption {
          type = types.str;
          default = defaultCategory;
          description = "Fresh download category assigned to this instance.";
        };
        profile = mkOption {
          type = types.enum profiles;
          default = builtins.head profiles;
          description = "Selected configuration profile name.";
        };
        sharedWritablePaths = mkOption {
          type = types.listOf dataPathType;
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
      compute,
      instanceName,
      cfg,
    }:
    let
      state = retainedEntry compute cfg.state;
      route = routeFor {
        inherit
          cluster
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
    assert lib.assertMsg (lib.elem "/data" cfg.sharedWritablePaths)
      "Media instance ${kind}/${instanceName} must explicitly declare shared writable path /data.";
    {
      fullnameOverride = service;
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
                inherit port;
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
        ports.http.port = port;
      };
      persistence = {
        config = {
          type = "persistentVolumeClaim";
          existingClaim = "media-${cfg.state}";
          globalMounts = [ { path = "/config"; } ];
        };
        data = {
          type = "hostPath";
          hostPath = "${compute.devices.media.path}/data";
          hostPathType = "Directory";
          globalMounts = [ { path = "/data"; } ];
        };
      };
    };
  mkArrApplications =
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
        namespace = app.namespace;
        helm.releases.${serviceName kind instanceName} = {
          chart = charts.bjw-s-labs.app-template;
          values = mkArrValues {
            inherit
              cluster
              compute
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
    type = types.attrsOf instanceType;
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
        compute,
        charts,
        ...
      }:
      {
        applications = mkArrApplications { inherit cluster compute charts; } // {
          "${kind}-storage" = {
            namespace = "media";
            retained = true;
            objects = lib.concatMap (cfg: mkStorage compute cfg.state "5Gi") (
              builtins.attrValues cluster.settings.kubernetes.services.media.${kind}
            );
          };
        };
      };
  };
}
