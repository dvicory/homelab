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
  den.aspects.kubernetes.services.jellyfin.settings.administrator = lib.mkOption {
    # Jellyfin 12.1 UserManager.ThrowIfInvalidUsername accepts
    # ^(?!\s)[\w\ \-'._@+]+(?<!\s)$ except "." and "..". The patched
    # provisioner checks only that the name is not blank, then fails partway
    # through provisioning on any other name. Accept the ASCII subset of that
    # rule here so a bad name fails evaluation instead.
    type = lib.types.addCheck (lib.types.strMatching "[A-Za-z0-9_.'@+-]([A-Za-z0-9_ .'@+-]*[A-Za-z0-9_.'@+-])?") (
      name: name != "." && name != ".."
    );
    default = "daniel";
    description = ''
      Initial declarative Jellyfin administrator name: ASCII letters, digits,
      spaces (not leading or trailing), and `_ . ' @ + -`, other than `.` or `..`.
    '';
  };

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
      images = [ packages.jellyfin-provisioner-image ];
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
      provisionerImage = "${provisioner.imageName}:${provisioner.imageTag}";
      runtimeImage = "${provisionerRelease.runtimeImage}@${provisionerRelease.runtimeDigest}";
      administrator = cluster.settings.kubernetes.services.jellyfin.administrator;
      mediaPath = computeResources.mediaPaths.library;
      route = cluster.routes.jellyfin;
      prefix = lib.optionalString (route.pathPrefix != "/") (lib.removeSuffix "/" route.pathPrefix);
      labels = {
        "app.kubernetes.io/controller" = "main";
        "app.kubernetes.io/instance" = "jellyfin";
        "app.kubernetes.io/name" = "jellyfin";
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
    in
    assert lib.assertMsg (
      route.namespace == namespace
      && route.service == "jellyfin"
      && route.port == 8096
      && !route.backendTLS
    ) "Jellyfin route must target its declared HTTP Service jellyfin/jellyfin:8096";
    # One coupled release identity. The provisioner build must use the
    # declared source, the stock runtime tag must name the same version, and
    # the whole declaration must equal the reviewed release below. A Jellyfin
    # upgrade edits the package declaration, this reviewed release and the
    # acceptance evidence in one change; moving either side alone fails here.
    # modules/tests/jellyfin-contracts.nix proves each drift is rejected.
    assert lib.assertMsg (
      provisioner.passthru.provisioner.version == provisionerRelease.version
      && provisioner.passthru.provisioner.src.rev == provisionerRelease.sourceRev
    ) "Jellyfin provisioner build does not use the declared release source";
    assert lib.assertMsg (
      provisionerRelease.runtimeImage == "docker.io/jellyfin/jellyfin:${provisionerRelease.version}"
    ) "Jellyfin stock runtime image tag must equal the provisioner release version";
    assert lib.assertMsg (
      provisionerRelease == {
        version = "12.1";
        sourceRev = "ee91c75e777da41a9c4f4855e70adc604fbf2ef8";
        runtimeImage = "docker.io/jellyfin/jellyfin:12.1";
        runtimeDigest = "sha256:78d3ea1207d1322471fcac39a614f004f2ccf7e878f95ab2977d752f07e4dd7e";
        provisionPatchRev = "8b0a2c269d5a3d9d7084b5295fd818a8a67af6f2";
      }
    ) "Jellyfin release declaration differs from the reviewed coupled release";
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
                      env = [
                        {
                          name = "JELLYFIN_ADMINISTRATOR";
                          value = administrator;
                        }
                      ];
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
                          ephemeral-storage = "4Gi";
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
                        defaultMode = 292;
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
    };
}
