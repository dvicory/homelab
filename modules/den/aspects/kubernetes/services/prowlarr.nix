{ lib, ... }:
let
  # Container IDs coincide with host service-account numbers by convention only.
  identity = {
    uid = 755;
    gid = 755;
  };
  app = {
    namespace = "media";
    service = "prowlarr";
    port = 9696;
    memory = "1Gi";
  };
  image = {
    repository = "ghcr.io/linuxserver/prowlarr";
    tag = "2.5.2.5491-ls159";
    digest = "sha256:c7502a75b021d964481c129c84590b9cbc40f83aadd4e553f173871bc0deaa3c";
  };
  apiSecretKey = "PROWLARR_API_KEY";
  retainedEntry =
    computeResources: key:
    assert lib.assertMsg (builtins.hasAttr key computeResources.retainedPaths)
      "Media state ${key} is not declared in computeResources.retainedPaths.";
    builtins.getAttr key computeResources.retainedPaths;
  routePrefix = route: if route.pathPrefix == "/" then "" else lib.removeSuffix "/" route.pathPrefix;
  secretRef = secretName: key: {
    valueFrom.secretKeyRef = {
      name = secretName;
      inherit key;
    };
  };
in
{
  den.aspects.kubernetes.services.prowlarr.compute-resources = { cluster, ... }: {
    retainedPaths.prowlarr = {
      inherit (identity) uid gid;
      mode = "0700";
    };
    runtimeSecrets."media--${cluster.settings.kubernetes.services.media.configurationSecret}--${apiSecretKey}" =
      {
        namespace = "media";
        name = cluster.settings.kubernetes.services.media.configurationSecret;
        key = apiSecretKey;
        generator = "api-key";
      };
  };
  den.aspects.kubernetes.services.prowlarr.k8s-manifests =
    {
      cluster,
      computeResources,
      charts,
      config,
      ...
    }:
    let
      state = retainedEntry computeResources "prowlarr";
      route =
        assert lib.assertMsg (builtins.hasAttr "prowlarr" cluster.routes)
          "Media route prowlarr is not declared.";
        let
          value = cluster.routes.prowlarr;
        in
        assert lib.assertMsg (
          value.namespace == app.namespace && value.service == app.service && value.port == app.port
        ) "Media route prowlarr must target ${app.namespace}/${app.service}:${toString app.port}.";
        value;
      prefix = routePrefix route;
      secretName = cluster.settings.kubernetes.services.media.configurationSecret;
    in
    assert lib.assertMsg (!state.readOnly) "Media state prowlarr must be writable.";
    {
      config.applications.prowlarr = {
        namespace = app.namespace;
        annotations."argocd.argoproj.io/sync-wave" = "1";
        helm.releases.prowlarr = {
          chart = charts.bjw-s-labs.app-template;
          values = {
            fullnameOverride = app.service;
            defaultPodOptions = {
              nodeSelector."kubernetes.io/hostname" = computeResources.instance;
              automountServiceAccountToken = false;
            };
            controllers.main = {
              type = "deployment";
              strategy = "Recreate";
              replicas = 1;
              containers.main = {
                image = image;
                env = {
                  TZ = "UTC";
                  PUID = toString identity.uid;
                  PGID = toString identity.gid;
                  UMASK = "007";
                  PROWLARR__AUTH__APIKEY = secretRef secretName apiSecretKey;
                  PROWLARR__SERVER__URLBASE = prefix;
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
            persistence.config = {
              type = "persistentVolumeClaim";
              existingClaim = "media-prowlarr";
              globalMounts = [ { path = "/config"; } ];
            };
          };
        };
      };
    };
}
