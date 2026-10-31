{ lib, ... }:
let
  namespace = "portal";
  port = 7575;
  retain = {
    "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
  };
in
{
  den.aspects.kubernetes.services.homarr.settings.phase = lib.mkOption {
    type = lib.types.enum [
      "initial"
      "ready"
    ];
    default = "initial";
    description = "Publish Home only after private onboarding, admin-group assignment and board permissions are complete.";
  };
  den.aspects.kubernetes.services.homarr.compute-resources = _: {
    # Stock entrypoint starts as root, prepares writable paths, then su-exec
    # drops to this identity before nginx, Redis and Next.js start.
    retainedPaths.homarr = {
      uid = 1000;
      gid = 1000;
      mode = "0700";
    };
    runtimeSecrets."portal--homarr--SECRET_ENCRYPTION_KEY" = {
      inherit namespace;
      name = "homarr";
      key = "SECRET_ENCRYPTION_KEY";
      generator = { pkgs, ... }: ''
        value="$(${pkgs.openssl}/bin/openssl rand -hex 32)" || exit $?
        ${pkgs.coreutils}/bin/printf '%s' "$value"
      '';
    };
  };
  den.aspects.kubernetes.services.homarr.k8s-manifests =
    {
      cluster,
      computeResources,
      charts,
      ...
    }:
    let
      state = computeResources.retainedPaths.homarr;
      route = cluster.routes.home;
      ready = cluster.settings.kubernetes.services.homarr.phase == "ready";
      labels = {
        "app.kubernetes.io/controller" = "main";
        "app.kubernetes.io/instance" = "homarr";
        "app.kubernetes.io/name" = "homarr";
      };
    in
    assert lib.assertMsg (!state.readOnly) "Homarr retained state must be writable.";
    assert lib.assertMsg (
      route.namespace == namespace
      && route.service == "homarr"
      && route.port == port
      && route.pathPrefix == "/"
      && route.auth == "native"
      && !route.backendTLS
      && !route.sameNamespaceIngress
      && !route.manageBackendIngress
      && route.backendPodSelector == labels
    ) "Home must use Homarr's native authentication and module-owned ingress policy.";
    {
      applications.homarr-retained = {
        inherit namespace;
        retained = true;
        resources = {
          namespaces.portal.metadata.annotations = retain;
          persistentVolumes.homarr = {
            metadata.annotations = retain;
            spec = {
              capacity.storage = "5Gi";
              accessModes = [ "ReadWriteOnce" ];
              persistentVolumeReclaimPolicy = "Retain";
              storageClassName = "";
              claimRef = {
                inherit namespace;
                name = "homarr";
              };
              local.path = state.guestPath;
              nodeAffinity.required.nodeSelectorTerms = [
                {
                  matchExpressions = [
                    {
                      key = "kubernetes.io/hostname";
                      operator = "In";
                      values = [ computeResources.instance ];
                    }
                  ];
                }
              ];
            };
          };
          persistentVolumeClaims.homarr = {
            metadata.annotations = retain;
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              storageClassName = "";
              volumeName = "homarr";
              resources.requests.storage = "5Gi";
            };
          };
        };
      };
      applications.homarr = {
        inherit namespace;
        # Identity's wave-2 PostSync Job publishes homarr-oidc before this Pod.
        annotations."argocd.argoproj.io/sync-wave" = "3";
        resources.networkPolicies.homarr-ingress.spec = {
          podSelector.matchLabels = labels;
          policyTypes = [ "Ingress" ];
          # Always isolate the Pod, including while the public route is absent.
          # API-server port-forward remains the private onboarding path.
          ingress = lib.optional ready {
            from = [
              {
                namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "gateway";
                podSelector.matchLabels = {
                  "gateway.envoyproxy.io/owning-gateway-namespace" = "gateway";
                  "gateway.envoyproxy.io/owning-gateway-name" = "household";
                };
              }
            ];
            ports = [
              {
                protocol = "TCP";
                inherit port;
              }
            ];
          };
        };
        helm.releases.homarr = {
          chart = charts.bjw-s-labs.app-template;
          values = {
            fullnameOverride = "homarr";
            defaultPodOptions = {
              nodeSelector."kubernetes.io/hostname" = computeResources.instance;
              automountServiceAccountToken = false;
            };
            controllers.main = {
              type = "statefulset";
              strategy = "RollingUpdate";
              replicas = 1;
              containers.main = {
                image = {
                  repository = "ghcr.io/homarr-labs/homarr";
                  tag = "v2.10.1";
                  digest = "sha256:2844201f11ce28b98183728dea2261de2b4fd8ed5480a4eef0b7977cc1a08dc0";
                };
                env = {
                  TZ = "UTC";
                  PUID = toString state.uid;
                  PGID = toString state.gid;
                  AUTH_PROVIDERS = "oidc";
                  AUTH_SESSION_EXPIRY_TIME = "1h";
                  AUTH_OIDC_ISSUER = "https://${builtins.head cluster.routes.idm.hostnames}/oauth2/openid/homarr";
                  AUTH_OIDC_CLIENT_ID = "homarr";
                  AUTH_OIDC_CLIENT_NAME = "Homelab";
                  AUTH_OIDC_CLIENT_SECRET.valueFrom.secretKeyRef = {
                    name = "homarr-oidc";
                    key = "clientSecret";
                  };
                  AUTH_OIDC_SCOPE_OVERWRITE = "openid profile email groups_name";
                  AUTH_OIDC_GROUPS_ATTRIBUTE = "groups";
                  AUTH_OIDC_GROUPS_LOCAL_MANAGEMENT = "false";
                  AUTH_OIDC_ENABLE_DANGEROUS_ACCOUNT_LINKING = "false";
                  AUTH_OIDC_ENABLE_DANGEROUS_CREDENTIALS_LINKING = "false";
                  AUTH_OIDC_TOKEN_ENDPOINT_AUTH_METHOD = "client_secret_basic";
                  SECRET_ENCRYPTION_KEY.valueFrom.secretKeyRef = {
                    name = "homarr";
                    key = "SECRET_ENCRYPTION_KEY";
                  };
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities = {
                    drop = [ "ALL" ];
                    # Required only by the stock chown + su-exec entrypoint.
                    add = [
                      "CHOWN"
                      "DAC_OVERRIDE"
                      "SETUID"
                      "SETGID"
                    ];
                  };
                  runAsUser = 0;
                  runAsGroup = 0;
                  seccompProfile.type = "RuntimeDefault";
                };
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "256Mi";
                  };
                  limits = {
                    cpu = "2";
                    memory = "1Gi";
                  };
                };
                probes = {
                  startup = {
                    enabled = true;
                    custom = true;
                    spec = {
                      httpGet = {
                        inherit port;
                        path = "/api/health/live";
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
                        inherit port;
                        path = "/api/health/live";
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
                        inherit port;
                        path = "/api/health/live";
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
              ports.http.port = port;
            };
            persistence.appdata = {
              type = "persistentVolumeClaim";
              existingClaim = "homarr";
              globalMounts = [ { path = "/appdata"; } ];
            };
          };
        };
      };
    };
}
