{ lib, ... }:
let
  # Jellyfin 10.11.11, pinned independently of the node's nixpkgs update.
  imageName = "jellyfin/jellyfin";
  imagePins = {
    "x86_64-linux" = {
      digest = "sha256:0b901391a662862eddb5dc55d244d7883cbb6236ef5b9a6ea82abc78a89819f0";
      hash = "sha256-fxbzgklRCoL3h/5UQyo72BbJFaEtClvWsUwy2n9DPtI=";
    };
    "aarch64-linux" = {
      digest = "sha256:7536c1009c6ea50dadd2b244165efb357504ca0f2670abefbceb1c773cc7e13d";
      hash = "sha256-cBRppWXdJvlinEJUX90rr4Kte9Fqly+ELWaBufWEOT4=";
    };
  };
  imageFor =
    { pkgs }:
    let
      system = pkgs.stdenv.hostPlatform.system;
      pin = imagePins.${system} or (throw "Jellyfin image is not pinned for ${system}");
      # Docker archives do not preserve the registry manifest digest. Import
      # under a content-named tag instead of falling back to a registry pull.
      tag = builtins.replaceStrings [ ":" ] [ "-" ] pin.digest;
    in
    {
      inherit pin system;
      reference = "${imageName}:${tag}";
      image = pkgs.dockerTools.pullImage {
        inherit imageName;
        imageDigest = pin.digest;
        hash = pin.hash;
        finalImageTag = tag;
      };
    };
  applicationFor =
    { pkgs }:
    let
      jellyfin = imageFor { inherit pkgs; };
      securityContext = {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        runAsNonRoot = true;
        runAsUser = 751;
        runAsGroup = 751;
        seccompProfile.type = "RuntimeDefault";
      };
      retained = [
        {
          apiVersion = "v1";
          kind = "Namespace";
          metadata = {
            name = "jellyfin";
            labels."app.kubernetes.io/name" = "jellyfin";
          };
        }
        {
          apiVersion = "v1";
          kind = "PersistentVolume";
          metadata = {
            name = "jellyfin-config";
            labels."app.kubernetes.io/name" = "jellyfin";
          };
          spec = {
            capacity.storage = "20Gi";
            accessModes = [ "ReadWriteOnce" ];
            persistentVolumeReclaimPolicy = "Retain";
            storageClassName = "jellyfin-retained";
            volumeMode = "Filesystem";
            local.path = "/srv/jellyfin/config";
            nodeAffinity.required.nodeSelectorTerms = [
              {
                matchExpressions = [
                  {
                    key = "kubernetes.io/hostname";
                    operator = "In";
                    values = [ "compute-1" ];
                  }
                ];
              }
            ];
          };
        }
        {
          apiVersion = "v1";
          kind = "PersistentVolumeClaim";
          metadata = {
            name = "jellyfin-config";
            namespace = "jellyfin";
            labels."app.kubernetes.io/name" = "jellyfin";
          };
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            storageClassName = "jellyfin-retained";
            volumeName = "jellyfin-config";
            resources.requests.storage = "20Gi";
          };
        }
      ];
      workload = [
        {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata = {
            name = "jellyfin";
            namespace = "jellyfin";
            labels."app.kubernetes.io/name" = "jellyfin";
          };
          spec = {
            replicas = 1;
            strategy.type = "Recreate";
            selector.matchLabels."app.kubernetes.io/name" = "jellyfin";
            template = {
              metadata.labels."app.kubernetes.io/name" = "jellyfin";
              spec = {
                automountServiceAccountToken = false;
                nodeSelector."kubernetes.io/hostname" = "compute-1";
                terminationGracePeriodSeconds = 30;
                initContainers = [
                  {
                    name = "media-source-check";
                    image = jellyfin.reference;
                    imagePullPolicy = "Never";
                    command = [
                      "/bin/sh"
                      "-ec"
                      ''
                        found=0
                        while IFS= read -r line; do
                          case "$line" in
                            *" /media/data "*) found=1 ;;
                          esac
                        done < /proc/self/mountinfo
                        test "$found" = 1
                        test -d /media/data
                        test -r /media/data
                      ''
                    ];
                    securityContext = securityContext;
                    volumeMounts = [
                      {
                        name = "media";
                        mountPath = "/media";
                        readOnly = true;
                        mountPropagation = "HostToContainer";
                      }
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
                  }
                ];
                containers = [
                  {
                    name = "jellyfin";
                    image = jellyfin.reference;
                    imagePullPolicy = "Never";
                    securityContext = securityContext // {
                      readOnlyRootFilesystem = false;
                    };
                    ports = [
                      {
                        name = "http";
                        containerPort = 8096;
                        protocol = "TCP";
                      }
                    ];
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
                    startupProbe = {
                      httpGet = {
                        path = "/health";
                        port = "http";
                      };
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = 30;
                    };
                    readinessProbe = {
                      httpGet = {
                        path = "/health";
                        port = "http";
                      };
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = 3;
                    };
                    livenessProbe = {
                      httpGet = {
                        path = "/health";
                        port = "http";
                      };
                      periodSeconds = 30;
                      timeoutSeconds = 5;
                      failureThreshold = 3;
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
                  }
                ];
                volumes = [
                  {
                    name = "config";
                    persistentVolumeClaim.claimName = "jellyfin-config";
                  }
                  {
                    name = "cache";
                    emptyDir.sizeLimit = "4Gi";
                  }
                  {
                    name = "media";
                    hostPath = {
                      path = "/srv/media";
                      type = "Directory";
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
            namespace = "jellyfin";
            labels."app.kubernetes.io/name" = "jellyfin";
          };
          spec = {
            type = "NodePort";
            selector."app.kubernetes.io/name" = "jellyfin";
            ports = [
              {
                name = "http";
                protocol = "TCP";
                port = 8096;
                targetPort = "http";
                nodePort = 30096;
              }
            ];
          };
        }
      ];
    in
    {
      inherit jellyfin retained workload;
    };
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system) (
      let
        application = applicationFor { inherit pkgs; };
        manifest =
          name: content:
          pkgs.writeText "jellyfin-${name}.yaml" (
            builtins.toJSON {
              apiVersion = "v1";
              kind = "List";
              items = content;
            }
            + "\n"
          );
      in
      {
        packages.jellyfin-kubernetes =
          pkgs.linkFarm "jellyfin-kubernetes" [
            {
              name = "image.tar";
              path = application.jellyfin.image;
            }
            {
              name = "image-reference";
              path = pkgs.writeText "jellyfin-image-reference" "${application.jellyfin.reference}\n";
            }
            {
              name = "retained.yaml";
              path = manifest "retained" application.retained;
            }
            {
              name = "workload.yaml";
              path = manifest "workload" application.workload;
            }
          ]
          // {
            passthru = {
              imageReference = application.jellyfin.reference;
              manifests = {
                retained = application.retained;
                workload = application.workload;
              };
            };
          };
      }
    );
}
