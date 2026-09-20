{ lib, ... }:
let
  # Container IDs coincide with host service-account numbers by convention only.
  identity = {
    uid = 755;
    gid = 755;
  };
  apps.prowlarr = {
    namespace = "media";
    service = "prowlarr";
    port = 9696;
    memory = "1Gi";
  };
  images.prowlarr = {
    repository = "ghcr.io/linuxserver/prowlarr";
    tag = "latest";
    digest = "sha256:c7502a75b021d964481c129c84590b9cbc40f83aadd4e553f173871bc0deaa3c";
  };
  inherit (import ./_media-lib.nix { inherit lib; })
    retainedEntry
    fixedRoute
    routePrefix
    secretRef
    mkStorage
    ;
  apiSecretKey = "PROWLARR_API_KEY";
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
      };
  };
  den.aspects.kubernetes.services.prowlarr.k8s-manifests =
    {
      cluster,
      compute,
      charts,
      ...
    }:
    let
      app = apps.prowlarr;
      state = retainedEntry compute "prowlarr";
      route = fixedRoute {
        cluster = cluster;
        name = "prowlarr";
        inherit app;
      };
      prefix = routePrefix route;
      secretName = cluster.settings.kubernetes.services.media.configurationSecret;
    in
    assert lib.assertMsg (!state.readOnly) "Media state prowlarr must be writable.";
    {
      applications.prowlarr-storage = {
        namespace = app.namespace;
        objects = mkStorage compute "prowlarr" "5Gi";
      };
      applications.prowlarr = {
        namespace = app.namespace;
        helm.releases.prowlarr = {
          chart = charts.bjw-s-labs.app-template;
          values = {
            fullnameOverride = app.service;
            defaultPodOptions = {
              nodeSelector."kubernetes.io/hostname" = compute.instance;
              automountServiceAccountToken = false;
            };
            controllers.main = {
              type = "deployment";
              strategy = "Recreate";
              replicas = 1;
              containers.main = {
                image = images.prowlarr;
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
