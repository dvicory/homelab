{ lib, config, ... }:
let
  # Jellyfin 10.11.11 as one multi-architecture registry reference. Registry
  # checks resolved this index to both linux/amd64 and linux/arm64, so rendered
  # manifests intentionally do not select an architecture from the renderer.
  jellyfinImage = {
    name = "jellyfin/jellyfin";
    version = "10.11.11";
    digest = "sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db";
    # Archive hashes pin the bytes produced when this index is copied for the
  # builder platform. They verify an offline recovery fixture; they do not
  # change the deployed image identity.
    fixtureArchiveHashes = {
      x86_64-linux = "sha256-HnH4Hr0t4MSWKdYAW5fDFX6juRHg0sdLP0e/O7Gmfwg=";
      aarch64-linux = "sha256-3Hfg8vk0UOVQ19zRglciKO9aWMB0tAv1l+kkgXDDb5U=";
    };
  };
  retain = {
    "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
  };
  # The workload's own identity. The numbers coincide with host service-account
  # numbers by convention; they are not derived from that registry.
  identity = {
    uid = 751;
    gid = 751;
  };
  # The storage capability, which is a different thing: the layout root is
  # root:media 2770, so without the group this workload cannot even traverse it.
  mediaGid = (config.den.groups or { }).media.gid;
in
{
  den.aspects.kubernetes.services.jellyfin.compute-resources.retainedPaths.jellyfin-config = {
    inherit (identity) uid gid;
    mode = "0750";
  };
  den.aspects.kubernetes.services.jellyfin.k8s-manifests =
    {
      cluster,
      compute,
      charts,
      ...
    }:
    let
      image = {
        repository = jellyfinImage.name;
        tag = "${jellyfinImage.version}@${jellyfinImage.digest}";
        pullPolicy = "IfNotPresent";
      };
      route = cluster.routes.jellyfin;
      prefix = lib.optionalString (route.pathPrefix != "/") (lib.removeSuffix "/" route.pathPrefix);
      security = {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        seccompProfile.type = "RuntimeDefault";
      };
    in
    assert lib.assertMsg (
      route.namespace == "jellyfin"
      && route.service == "jellyfin"
      && route.port == 8096
      && !route.backendTLS
    ) "Jellyfin route must target its declared HTTP Service jellyfin/jellyfin:8096";
    {
      applications.jellyfin-retained = {
        namespace = "jellyfin";
        resources = {
          namespaces.jellyfin.metadata.annotations = retain;
          persistentVolumes.jellyfin-config = {
            metadata.annotations = retain;
            spec = {
              capacity.storage = "20Gi";
              accessModes = [ "ReadWriteOnce" ];
              persistentVolumeReclaimPolicy = "Retain";
              storageClassName = "jellyfin-retained";
              volumeMode = "Filesystem";
              local.path = compute.retainedPaths.jellyfin-config.guestPath;
              nodeAffinity.required.nodeSelectorTerms = [
                {
                  matchExpressions = [
                    {
                      key = "kubernetes.io/hostname";
                      operator = "In";
                      values = [ compute.instance ];
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
              storageClassName = "jellyfin-retained";
              volumeName = "jellyfin-config";
              resources.requests.storage = "20Gi";
            };
          };
        };
      };
      applications.jellyfin = {
        namespace = "jellyfin";
        helm.releases.jellyfin = {
          chart = charts.bjw-s-labs.app-template;
          values = {
            defaultPodOptions = {
              nodeSelector."kubernetes.io/hostname" = compute.instance;
              automountServiceAccountToken = false;
              securityContext = {
                runAsUser = identity.uid;
                runAsGroup = identity.gid;
                runAsNonRoot = true;
                supplementalGroups = [ mediaGid ];
              };
            };
            controllers.main = {
              type = "deployment";
              replicas = 1;
              strategy = "Recreate";
              initContainers.prepare = {
                inherit image;
                securityContext = security;
                command = [
                  "/bin/sh"
                  "-ec"
                  ''
                    found=0
                    while IFS= read -r line; do
                      case "$line" in *" /media "*) found=1 ;; esac
                    done < /proc/self/mountinfo
                    test "$found" = 1
                    test -d /media && test -r /media
                    mkdir -p /config/config
                    cp /network/network.xml /config/config/network.xml.new
                    mv /config/config/network.xml.new /config/config/network.xml
                  ''
                ];
                resources = {
                  requests = {
                    cpu = "10m";
                    memory = "16Mi";
                  };
                  limits = {
                    cpu = "100m";
                    memory = "64Mi";
                    ephemeral-storage = "64Mi";
                  };
                };
              };
              containers.main = {
                inherit image;
                securityContext = security;
                env.JELLYFIN_PublishedServerUrl = "https://${builtins.head route.hostnames}${prefix}";
                probes = {
                  startup = {
                    enabled = true;
                    custom = true;
                    spec = {
                      httpGet = {
                        path = "${prefix}/health";
                        port = 8096;
                      };
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = 30;
                    };
                  };
                  readiness = {
                    enabled = true;
                    custom = true;
                    spec = {
                      httpGet = {
                        path = "${prefix}/health";
                        port = 8096;
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
                        path = "${prefix}/health";
                        port = 8096;
                      };
                      periodSeconds = 30;
                      timeoutSeconds = 5;
                    };
                  };
                };
                resources = {
                  requests = {
                    cpu = "500m";
                    memory = "512Mi";
                  };
                  limits = {
                    cpu = "2";
                    memory = "2Gi";
                    ephemeral-storage = "1Gi";
                  };
                };
              };
            };
            service.main = {
              controller = "main";
              type = "ClusterIP";
              ports.http = {
                port = 8096;
                targetPort = 8096;
              };
            };
            configMaps.network.data."network.xml" = ''
              <?xml version="1.0" encoding="utf-8"?>
              <NetworkConfiguration>
                <BaseUrl>${lib.escapeXML prefix}</BaseUrl>
                <InternalHttpPort>8096</InternalHttpPort>
                <EnableIPv4>true</EnableIPv4>
                <EnableIPv6>false</EnableIPv6>
                <EnableHttps>false</EnableHttps>
                <RequireHttps>false</RequireHttps>
                <EnableRemoteAccess>true</EnableRemoteAccess>
              </NetworkConfiguration>
            '';
            persistence = {
              config = {
                existingClaim = "jellyfin-config";
                globalMounts = [ { path = "/config"; } ];
              };
              cache = {
                type = "emptyDir";
                sizeLimit = "4Gi";
                globalMounts = [ { path = "/cache"; } ];
              };
              media = {
                type = "hostPath";
                hostPath = "${compute.devices.media.path}/library";
                hostPathType = "Directory";
                globalMounts = [
                  {
                    path = "/media";
                    readOnly = true;
                    mountPropagation = "HostToContainer";
                  }
                ];
              };
              network = {
                type = "configMap";
                identifier = "network";
                globalMounts = [
                  {
                    path = "/network";
                    readOnly = true;
                  }
                ];
              };
            };
          };
        };
      };
    };

  # Optional offline image input for recovery fixtures; application rendering
  # and release ownership remain in Nixidy, not a parallel manifest package.
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system) {
      packages.jellyfin-image =
        let
          tag = "${jellyfinImage.version}-fixture";
        in
        (pkgs.dockerTools.pullImage {
          imageName = jellyfinImage.name;
          imageDigest = jellyfinImage.digest;
          hash = jellyfinImage.fixtureArchiveHashes.${system};
          finalImageTag = tag;
        }).overrideAttrs
          (old: {
            passthru = (old.passthru or { }) // {
              imageReference = "${jellyfinImage.name}:${tag}";
            };
          });
    };
}
