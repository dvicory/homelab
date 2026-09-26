{ lib, ... }:
let
  apps.seerr = {
    namespace = "media";
    service = "seerr";
    port = 5055;
    memory = "1Gi";
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
  den.aspects.kubernetes.services.seerr.compute-resources = { cluster, ... }: {
    retainedPaths.seerr = {
      uid = 1000;
      gid = 1000;
      mode = "0700";
    };
    runtimeSecrets."media--${cluster.settings.kubernetes.services.media.configurationSecret}--SEERR_API_KEY" =
      {
        namespace = "media";
        name = cluster.settings.kubernetes.services.media.configurationSecret;
        key = "SEERR_API_KEY";
      };
  };
  den.aspects.kubernetes.services.seerr.settings.phase = lib.mkOption {
    type = lib.types.enum [
      "initial"
      "ready"
    ];
    default = "initial";
    description = "Publish native-auth requests only after Seerr owner claim and Movies library sync succeed.";
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
      app = apps.seerr;
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
        helm.releases.seerr = {
          chart = charts.bjw-s-labs.app-template;
          values = {
            fullnameOverride = "seerr";
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
                    key = "SEERR_API_KEY";
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
