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
  inherit (import ./_media-lib.nix { inherit lib; }) retainedEntry fixedRoute mkStorage;
in
{
  den.aspects.kubernetes.services.seerr.compute-resources.retainedPaths.seerr = {
    uid = 1000;
    gid = 1000;
    mode = "0700";
  };
  den.aspects.kubernetes.services.seerr.k8s-manifests =
    {
      cluster,
      compute,
      charts,
      ...
    }:
    let
      app = apps.seerr;
      state = retainedEntry compute "seerr";
      route = fixedRoute {
        cluster = cluster;
        name = "requests";
        inherit app;
      };
    in
    assert route != null;
    {
      applications.seerr-storage = {
        namespace = app.namespace;
        objects = mkStorage compute "seerr" "5Gi";
      };
      applications.seerr = {
        namespace = app.namespace;
        helm.releases.seerr = {
          chart = charts.bjw-s-labs.app-template;
          values = {
            fullnameOverride = "seerr";
            defaultPodOptions = {
              nodeSelector."kubernetes.io/hostname" = compute.instance;
              automountServiceAccountToken = false;
            };
            controllers.main = {
              type = "statefulset";
              strategy = "RollingUpdate";
              replicas = 1;
              containers.main = {
                image = images.seerr;
                env.TZ = "UTC";
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
