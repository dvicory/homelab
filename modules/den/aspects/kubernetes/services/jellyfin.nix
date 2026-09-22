{
  config,
  inputs,
  lib,
  ...
}:
let
  namespace = "jellyfin";
  retain = {
    "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
  };
  identity = {
    uid = 751;
    gid = 751;
  };
  mediaGid = (config.den.groups or { }).media.gid;
in
{
  den.aspects.kubernetes.services.jellyfin.compute-resources =
    { cluster, ... }:
    let
      hostCompute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      linuxSystem =
        inputs.self.nixosConfigurations.${hostCompute.instance}.pkgs.stdenv.hostPlatform.system;
      packages = inputs.self.packages.${linuxSystem};
    in
    {
      images = [
        packages.jellyfin-provisioner-image
        packages.jellarr-image
      ];
      retainedPaths.jellyfin-config = {
        inherit (identity) uid gid;
        mode = "0750";
      };
      runtimeSecrets."jellyfin--jellyfin-admin--password" = {
        inherit namespace;
        name = "jellyfin-admin";
        key = "password";
      };
    };

  den.aspects.kubernetes.services.jellyfin.k8s-manifests =
    {
      cluster,
      computeResources,
      ...
    }:
    let
      linuxSystem =
        inputs.self.nixosConfigurations.${computeResources.instance}.pkgs.stdenv.hostPlatform.system;
      packages = inputs.self.packages.${linuxSystem};
      provisioner = packages.jellyfin-provisioner-image;
      provisionerRelease = provisioner.passthru.release;
      jellarr = packages.jellarr-image;
      jellarrRelease = jellarr.passthru.release;
      provisionerImage = "${provisioner.imageName}:${provisioner.imageTag}";
      runtimeImage = "${provisionerRelease.runtimeImage}@${provisionerRelease.runtimeDigest}";
      jellarrImage = "${jellarrRelease.imageName}:${jellarrRelease.imageTag}";
      mediaPath = "/srv/media/data/library";
      route = cluster.routes.jellyfin;
      prefix = lib.optionalString (route.pathPrefix != "/") (lib.removeSuffix "/" route.pathPrefix);
      labels = {
        "app.kubernetes.io/controller" = "main";
        "app.kubernetes.io/instance" = "jellyfin";
        "app.kubernetes.io/name" = "jellyfin";
      };
      configurationLabels = {
        "app.kubernetes.io/instance" = "jellyfin-configuration";
        "app.kubernetes.io/name" = "jellarr";
      };
      podSecurity = {
        runAsUser = identity.uid;
        runAsGroup = identity.gid;
        runAsNonRoot = true;
        seccompProfile.type = "RuntimeDefault";
      };
      containerSecurity = podSecurity // {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
      };
      jellarrConfig = ''
        version: 1
        base_url: http://jellyfin.jellyfin.svc.cluster.local:8096
        system:
          enableMetrics: true
        library:
          virtualFolders:
            - name: Movies
              collectionType: movies
              libraryOptions:
                pathInfos:
                  - path: /media
      '';
      bootstrapScript = ''
        import fs from "node:fs";

        const baseUrl = process.env.JELLYFIN_URL;
        const password = fs.readFileSync("/run/secrets/password", "utf8").replace(/\r?\n$/, "");
        const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

        async function request(path, options = {}) {
          const response = await fetch(baseUrl + path, options);
          const body = await response.text();
          if (!response.ok) {
            throw new Error("Jellyfin API request failed: " + response.status);
          }
          return body.trim() === "" ? null : JSON.parse(body);
        }

        let healthy = false;
        for (let attempt = 0; attempt < 60; attempt += 1) {
          try {
            const response = await fetch(baseUrl + "/health");
            if (response.ok) {
              healthy = true;
              break;
            }
          } catch (_) {
            // The stock Service can exist before its Pod is ready.
          }
          await sleep(2000);
        }
        if (!healthy) {
          throw new Error("Jellyfin did not become healthy before the deadline");
        }

        const authentication = await request("/Users/AuthenticateByName", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: 'MediaBrowser Client="homelab-jellarr-bootstrap", Device="Kubernetes Job", DeviceId="jellarr-bootstrap", Version="1"',
          },
          body: JSON.stringify({ Username: "admin", Pw: password }),
        });
        const administratorToken = authentication.AccessToken || authentication.accessToken;
        if (!administratorToken) {
          throw new Error("Jellyfin administrator authentication returned no token");
        }
        const headers = {
          "Content-Type": "application/json",
          "X-Emby-Token": administratorToken,
        };
        const keyName = "Jellarr";
        const namedKey = (response) =>
          (response.Items || response.items || []).filter(
            (key) => (key.AppName || key.appName) === keyName
          );
        let keys = namedKey(await request("/Auth/Keys", { headers }));
        if (keys.length > 1) {
          throw new Error("More than one Jellarr API key exists");
        }
        if (keys.length === 0) {
          await request("/Auth/Keys?app=Jellarr", { method: "POST", headers });
          keys = namedKey(await request("/Auth/Keys", { headers }));
        }
        if (keys.length !== 1) {
          throw new Error("Jellarr API key was not available after creation");
        }
        const apiKey = keys[0].AccessToken || keys[0].accessToken;
        if (!apiKey) {
          throw new Error("Jellarr API key response contained no token");
        }
        fs.writeFileSync("/run/jellarr/api-key", apiKey + "\n", { mode: 0o400 });
      '';
    in
    assert lib.assertMsg (
      route.namespace == namespace
      && route.service == "jellyfin"
      && route.port == 8096
      && !route.backendTLS
    ) "Jellyfin route must target its declared HTTP Service jellyfin/jellyfin:8096";
    assert lib.assertMsg (
      provisionerRelease.version == "12.1"
      && provisionerRelease.runtimeImage == "docker.io/jellyfin/jellyfin:12.1"
      &&
        provisionerRelease.runtimeDigest
        == "sha256:78d3ea1207d1322471fcac39a614f004f2ccf7e878f95ab2977d752f07e4dd7e"
    ) "Jellyfin provisioner/runtime release identity drifted";
    {
      applications.jellyfin-retained = {
        inherit namespace;
        retained = true;
        resources = {
          namespaces.jellyfin.metadata.annotations = retain;
          persistentVolumes.jellyfin-config = {
            metadata.annotations = retain;
            spec = {
              capacity.storage = "20Gi";
              accessModes = [ "ReadWriteOnce" ];
              persistentVolumeReclaimPolicy = "Retain";
              storageClassName = "";
              claimRef = {
                inherit namespace;
                name = "jellyfin-config";
              };
              local.path = computeResources.retainedPaths.jellyfin-config.guestPath;
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
          persistentVolumeClaims.jellyfin-config = {
            metadata.annotations = retain;
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              storageClassName = "";
              volumeName = "jellyfin-config";
              resources.requests.storage = "20Gi";
            };
          };
        };
      };

      applications.jellyfin = {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "1";
        finalizer = "foreground";
        objects = [
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "jellyfin";
              inherit namespace labels;
            };
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels = labels;
              template = {
                metadata.labels = labels;
                spec = {
                  automountServiceAccountToken = false;
                  enableServiceLinks = false;
                  nodeSelector."kubernetes.io/hostname" = computeResources.instance;
                  securityContext = podSecurity // {
                    supplementalGroups = [ mediaGid ];
                  };
                  initContainers = [
                    {
                      name = "provision";
                      image = provisionerImage;
                      imagePullPolicy = "Never";
                      command = [ "/bin/jellyfin-provision" ];
                      resources = {
                        requests = {
                          cpu = "50m";
                          memory = "64Mi";
                        };
                        limits = {
                          cpu = "1";
                          memory = "512Mi";
                          ephemeral-storage = "128Mi";
                        };
                      };
                      securityContext = containerSecurity;
                      volumeMounts = [
                        {
                          name = "config";
                          mountPath = "/config";
                        }
                        {
                          name = "cache";
                          mountPath = "/cache";
                        }
                        {
                          name = "media";
                          mountPath = "/media";
                          readOnly = true;
                          mountPropagation = "HostToContainer";
                        }
                        {
                          name = "provision";
                          mountPath = "/run/provision";
                        }
                        {
                          name = "admin-password";
                          mountPath = "/run/secrets/password";
                          subPath = "password";
                          readOnly = true;
                        }
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "jellyfin";
                      image = runtimeImage;
                      imagePullPolicy = "IfNotPresent";
                      resources = {
                        requests = {
                          cpu = "500m";
                          memory = "512Mi";
                        };
                        limits = {
                          cpu = "2";
                          memory = "2Gi";
                          ephemeral-storage = "5Gi";
                        };
                      };
                      securityContext = containerSecurity;
                      startupProbe = {
                        httpGet = {
                          path = "${prefix}/Users/Public";
                          port = 8096;
                        };
                        periodSeconds = 10;
                        timeoutSeconds = 5;
                        failureThreshold = 30;
                      };
                      readinessProbe = {
                        httpGet = {
                          path = "${prefix}/Users/Public";
                          port = 8096;
                        };
                        periodSeconds = 10;
                        timeoutSeconds = 5;
                      };
                      livenessProbe = {
                        httpGet = {
                          path = "${prefix}/health";
                          port = 8096;
                        };
                        periodSeconds = 30;
                        timeoutSeconds = 5;
                      };
                      volumeMounts = [
                        {
                          name = "config";
                          mountPath = "/config";
                        }
                        {
                          name = "cache";
                          mountPath = "/cache";
                        }
                        {
                          name = "media";
                          mountPath = "/media";
                          readOnly = true;
                          mountPropagation = "HostToContainer";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "config";
                      persistentVolumeClaim.claimName = "jellyfin-config";
                    }
                    {
                      name = "cache";
                      emptyDir = {
                        sizeLimit = "4Gi";
                      };
                    }
                    {
                      name = "media";
                      hostPath = {
                        path = mediaPath;
                        type = "Directory";
                      };
                    }
                    {
                      name = "provision";
                      emptyDir = {
                        medium = "Memory";
                        sizeLimit = "16Mi";
                      };
                    }
                    {
                      name = "admin-password";
                      secret = {
                        secretName = "jellyfin-admin";
                        defaultMode = 256;
                        items = [
                          {
                            key = "password";
                            path = "password";
                          }
                        ];
                      };
                    }
                  ];
                };
              };
            };
          }
          {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "jellyfin";
              inherit namespace labels;
            };
            spec = {
              type = "ClusterIP";
              selector = labels;
              ports = [
                {
                  name = "http";
                  port = 8096;
                  targetPort = 8096;
                  protocol = "TCP";
                }
              ];
            };
          }
        ];
      };

      applications.jellyfin-configuration = {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "2";
        finalizer = "foreground";
        objects = [
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "jellarr-configuration";
              inherit namespace;
            };
            data = {
              "config.yml" = jellarrConfig;
              "bootstrap.mjs" = bootstrapScript;
            };
          }
          {
            apiVersion = "batch/v1";
            kind = "Job";
            metadata = {
              name = "jellyfin-configuration";
              inherit namespace;
              labels = configurationLabels;
              annotations = {
                "argocd.argoproj.io/hook" = "PostSync";
                "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
                "homelab.danielvicory/jellarr-config" = builtins.hashString "sha256" jellarrConfig;
              };
            };
            spec = {
              backoffLimit = 4;
              activeDeadlineSeconds = 600;
              template = {
                metadata.labels = configurationLabels;
                spec = {
                  restartPolicy = "Never";
                  automountServiceAccountToken = false;
                  enableServiceLinks = false;
                  nodeSelector."kubernetes.io/hostname" = computeResources.instance;
                  securityContext = podSecurity;
                  initContainers = [
                    {
                      name = "bootstrap";
                      image = jellarrImage;
                      imagePullPolicy = "Never";
                      command = [ "node" ];
                      args = [ "/config/bootstrap.mjs" ];
                      env = [
                        {
                          name = "JELLYFIN_URL";
                          value = "http://jellyfin.jellyfin.svc.cluster.local:8096";
                        }
                      ];
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "32Mi";
                        };
                        limits = {
                          cpu = "250m";
                          memory = "128Mi";
                          ephemeral-storage = "64Mi";
                        };
                      };
                      securityContext = containerSecurity;
                      volumeMounts = [
                        {
                          name = "configuration";
                          mountPath = "/config";
                          readOnly = true;
                        }
                        {
                          name = "admin-password";
                          mountPath = "/run/secrets/password";
                          subPath = "password";
                          readOnly = true;
                        }
                        {
                          name = "api-key";
                          mountPath = "/run/jellarr";
                        }
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "jellarr";
                      image = jellarrImage;
                      imagePullPolicy = "Never";
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "32Mi";
                        };
                        limits = {
                          cpu = "500m";
                          memory = "256Mi";
                          ephemeral-storage = "128Mi";
                        };
                      };
                      securityContext = containerSecurity;
                      volumeMounts = [
                        {
                          name = "configuration";
                          mountPath = "/config";
                          readOnly = true;
                        }
                        {
                          name = "api-key";
                          mountPath = "/run/jellarr";
                          readOnly = true;
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "configuration";
                      configMap = {
                        name = "jellarr-configuration";
                        defaultMode = 292;
                      };
                    }
                    {
                      name = "admin-password";
                      secret = {
                        secretName = "jellyfin-admin";
                        defaultMode = 256;
                        items = [
                          {
                            key = "password";
                            path = "password";
                          }
                        ];
                      };
                    }
                    {
                      name = "api-key";
                      emptyDir = {
                        medium = "Memory";
                        sizeLimit = "1Mi";
                      };
                    }
                  ];
                };
              };
            };
          }
        ];
      };
    };
}
