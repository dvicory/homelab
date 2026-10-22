{ lib, ... }:
let
  app = {
    namespace = "media";
    service = "seerr";
    port = 5055;
    memory = "1Gi";
    apiSecretKey = "SEERR_API_KEY";
  };
  images.seerr = {
    repository = "ghcr.io/seerr-team/seerr";
    tag = "v3.4.1";
    digest = "sha256:f4768de5f616248d723e05891f3345a1402123775d03bf0890dbfedc0831bda1";
  };
  retainedEntry =
    computeResources: key:
    assert lib.assertMsg (builtins.hasAttr key computeResources.retainedPaths)
      "Media state ${key} is not declared in computeResources.retainedPaths.";
    builtins.getAttr key computeResources.retainedPaths;
in
{
  den.aspects.kubernetes.services.seerr.settings.integration = lib.mkOption {
    type = lib.types.attrs;
    readOnly = true;
    default = {
      inherit (app)
        namespace
        service
        port
        apiSecretKey
        ;
    };
    description = "Read-only Seerr Service endpoint and API Secret key for consumers.";
  };
  den.aspects.kubernetes.services.seerr.compute-resources = { cluster, ... }: {
    retainedPaths.seerr = {
      uid = 1000;
      gid = 1000;
      mode = "0700";
    };
    runtimeSecrets."${app.namespace}--${cluster.settings.kubernetes.services.media.configurationSecret}--${app.apiSecretKey}" =
      {
        namespace = app.namespace;
        name = cluster.settings.kubernetes.services.media.configurationSecret;
        key = app.apiSecretKey;
      };
  };
  den.aspects.kubernetes.services.seerr.settings.phase = lib.mkOption {
    type = lib.types.enum [
      "initial"
      "ready"
    ];
    default = "initial";
    description = "Publish native-auth requests only after Seerr owner claim and Jellyfin library sync succeed.";
  };
  den.aspects.kubernetes.services.seerr.k8s-manifests =
    {
      cluster,
      computeResources,
      charts,
      config,
      ...
    }:
    let
      state = retainedEntry computeResources "seerr";
      route =
        assert lib.assertMsg (builtins.hasAttr "requests" cluster.routes)
          "Media route requests is not declared.";
        let
          value = cluster.routes.requests;
        in
        assert lib.assertMsg (
          value.namespace == app.namespace
          && value.service == app.service
          && value.port == app.port
          && value.pathPrefix == "/"
        ) "Media route requests must target ${app.namespace}/${app.service}:${toString app.port} at /.";
        value;
    in
    assert lib.assertMsg (!state.readOnly) "Media state seerr must be writable.";
    {
      config.applications.seerr = {
        namespace = app.namespace;
        annotations."argocd.argoproj.io/sync-wave" = "1";
        helm.releases.seerr = {
          chart = charts.bjw-s-labs.app-template;
          values = {
            fullnameOverride = app.service;
            defaultPodOptions = {
              nodeSelector."kubernetes.io/hostname" = computeResources.instance;
              automountServiceAccountToken = false;
            };
            controllers.main = {
              type = "statefulset";
              strategy = "RollingUpdate";
              replicas = 1;
              containers.main = {
                image = images.seerr;
                env = {
                  TZ = "UTC";
                  API_KEY.valueFrom.secretKeyRef = {
                    name = cluster.settings.kubernetes.services.media.configurationSecret;
                    key = app.apiSecretKey;
                  };
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = [ "ALL" ];
                  runAsUser = state.uid;
                  runAsGroup = state.gid;
                  runAsNonRoot = true;
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
                      httpGet = {
                        port = app.port;
                        path = "/api/v1/status";
                      };
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = 60;
                    };
                  };
                  readiness = {
                    enabled = true;
                    custom = true;
                    spec = {
                      httpGet = {
                        port = app.port;
                        path = "/api/v1/status";
                      };
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                    };
                  };
                  liveness = {
                    enabled = true;
                    custom = true;
                    spec = {
                      httpGet = {
                        port = app.port;
                        path = "/api/v1/status";
                      };
                      periodSeconds = 30;
                      timeoutSeconds = 5;
                    };
                  };
                };
              };
            };
            service.main = {
              controller = "main";
              ports.http.port = app.port;
            };
            persistence.config = {
              type = "persistentVolumeClaim";
              existingClaim = "media-seerr";
              globalMounts = [ { path = "/app/config"; } ];
            };
          };
        };
      };
    };
}
