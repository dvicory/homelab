{ lib, ... }:
let
  imageName = "jellyfin/jellyfin";
  imagePins = {
    x86_64-linux = {
      digest = "sha256:0b901391a662862eddb5dc55d244d7883cbb6236ef5b9a6ea82abc78a89819f0";
      hash = "sha256-fxbzgklRCoL3h/5UQyo72BbJFaEtClvWsUwy2n9DPtI=";
    };
    aarch64-linux = {
      digest = "sha256:7536c1009c6ea50dadd2b244165efb357504ca0f2670abefbceb1c773cc7e13d";
      hash = "sha256-cBRppWXdJvlinEJUX90rr4Kte9Fqly+ELWaBufWEOT4=";
    };
  };
  retain = { "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false"; };
in
{
  den.aspects.kubernetes.services.jellyfin.k8s-manifests =
    { cluster, charts, pkgs, ... }:
    let
      system = builtins.replaceStrings [ "darwin" ] [ "linux" ] pkgs.stdenv.hostPlatform.system;
      pin = imagePins.${system};
      image = {
        repository = imageName;
        tag = "10.11.11@${pin.digest}";
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
              local.path = "/srv/jellyfin/config";
              nodeAffinity.required.nodeSelectorTerms = [{
                matchExpressions = [{
                  key = "kubernetes.io/hostname";
                  operator = "In";
                  values = [ cluster.nodeName ];
                }];
              }];
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
              nodeSelector."kubernetes.io/hostname" = cluster.nodeName;
              automountServiceAccountToken = false;
              securityContext = { runAsUser = 751; runAsGroup = 751; runAsNonRoot = true; };
            };
            controllers.main = {
              type = "deployment";
              replicas = 1;
              strategy = "Recreate";
              initContainers.prepare = {
                inherit image;
                securityContext = security;
                command = [ "/bin/sh" "-ec" ''
                  found=0
                  while IFS= read -r line; do
                    case "$line" in *" /media/data "*) found=1 ;; esac
                  done < /proc/self/mountinfo
                  test "$found" = 1
                  test -d /media/data && test -r /media/data
                  mkdir -p /config/config
                  cp /network/network.xml /config/config/network.xml.new
                  mv /config/config/network.xml.new /config/config/network.xml
                '' ];
                resources = {
                  requests = { cpu = "10m"; memory = "16Mi"; };
                  limits = { cpu = "100m"; memory = "64Mi"; ephemeral-storage = "64Mi"; };
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
                      httpGet = { path = "${prefix}/health"; port = 8096; };
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = 30;
                    };
                  };
                  readiness = {
                    enabled = true;
                    custom = true;
                    spec = {
                      httpGet = { path = "${prefix}/health"; port = 8096; };
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                    };
                  };
                  liveness = {
                    enabled = true;
                    custom = true;
                    spec = {
                      httpGet = { path = "${prefix}/health"; port = 8096; };
                      periodSeconds = 30;
                      timeoutSeconds = 5;
                    };
                  };
                };
                resources = {
                  requests = { cpu = "500m"; memory = "512Mi"; };
                  limits = { cpu = "2"; memory = "2Gi"; ephemeral-storage = "1Gi"; };
                };
              };
            };
            service.main = {
              controller = "main";
              type = "ClusterIP";
              ports.http = { port = 8096; targetPort = 8096; };
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
              config = { existingClaim = "jellyfin-config"; globalMounts = [{ path = "/config"; }]; };
              cache = { type = "emptyDir"; sizeLimit = "4Gi"; globalMounts = [{ path = "/cache"; }]; };
              media = {
                type = "hostPath";
                hostPath = "/srv/media";
                hostPathType = "Directory";
                globalMounts = [{ path = "/media"; readOnly = true; mountPropagation = "HostToContainer"; }];
              };
              network = { type = "configMap"; identifier = "network"; globalMounts = [{ path = "/network"; readOnly = true; }]; };
            };
          };
        };
      };
    };

  # Optional offline image input for recovery fixtures; application rendering
  # and release ownership remain in Nixidy, not a parallel manifest package.
  perSystem = { pkgs, system, ... }: lib.optionalAttrs (lib.hasSuffix "-linux" system) {
    packages.jellyfin-image =
      let
        pin = imagePins.${system};
        tag = builtins.replaceStrings [ ":" ] [ "-" ] pin.digest;
      in
      (pkgs.dockerTools.pullImage {
        inherit imageName;
        imageDigest = pin.digest;
        hash = pin.hash;
        finalImageTag = tag;
      }).overrideAttrs (old: {
        passthru = (old.passthru or { }) // { imageReference = "${imageName}:${tag}"; };
      });
  };
}
