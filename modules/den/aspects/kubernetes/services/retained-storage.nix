{ inputs, ... }:
let
  namespace = "local-path-storage";
  storageClassName = "retained-local";
  provisionerName = "rancher.io/local-path";
  protect = {
    "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
  };
in
{
  den.aspects.kubernetes.services.retained-storage.k8s-manifests =
    { computeResources, lib, ... }:
    let
      chart = lib.helm.downloadHelmChart {
        repo = "oci://ghcr.io/rancher/local-path-provisioner/charts";
        chart = "local-path-provisioner";
        version = "0.0.34";
        chartHash = "sha256-vkjwkF+QvTZ/PRaOanyXrXfYCSe/wBcRatga0SgDel0=";
      };
      helperResources = {
        requests = {
          cpu = "10m";
          memory = "16Mi";
        };
        limits = {
          cpu = "100m";
          memory = "64Mi";
        };
      };
      helperImage = "busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0";
    in
    {
      applications.retained-storage = {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "-2";
        createNamespace = false;
        retained = true;
        objects = [
          {
            apiVersion = "v1";
            kind = "Namespace";
            metadata = {
              name = namespace;
              annotations = protect;
            };
          }
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "retained-directories";
              inherit namespace;
              annotations = protect;
            };
            # Application identities travel with Argo, not the node OS. This is
            # desired identity, not permission to create missing application data.
            data."directories.json" = builtins.toJSON (
              lib.mapAttrs (_: entry: {
                inherit (entry)
                  id
                  uid
                  gid
                  mode
                  ;
              }) computeResources.retainedPaths
            );
          }
          {
            apiVersion = "storage.k8s.io/v1";
            kind = "StorageClass";
            metadata = {
              name = storageClassName;
              annotations = protect // {
                defaultVolumeType = "local";
              };
            };
            provisioner = provisionerName;
            # Kubernetes validates both names before the provisioner sees them.
            # Namespace has no dots, so the first dot unambiguously separates it.
            parameters = {
              pathPattern = "{{ .PVC.Namespace }}.{{ .PVC.Name }}";
              allowUnsafePathPattern = "true";
            };
            volumeBindingMode = "WaitForFirstConsumer";
            reclaimPolicy = "Retain";
            allowVolumeExpansion = false;
            allowedTopologies = [
              {
                matchLabelExpressions = [
                  {
                    key = "kubernetes.io/hostname";
                    values = [ computeResources.instance ];
                  }
                ];
              }
            ];
          }
        ];
      };
      applications.local-path-provisioner = {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "-1";
        createNamespace = false;
        helm.releases.local-path-provisioner = {
          inherit chart;
          values = {
            image = {
              repository = "rancher/local-path-provisioner";
              tag = "v0.0.34@sha256:6ff68ebe98bc623b45ad22c28be84f8a08214982710f3247d5862e9bccce73ef";
              pullPolicy = "IfNotPresent";
            };
            helperImage = {
              repository = "busybox";
              tag = "1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0";
            };
            storageClass = {
              create = false;
              name = storageClassName;
              inherit provisionerName;
            };
            nodePathMap = [
              {
                node = computeResources.instance;
                paths = [ computeResources.stateRoot.guestPath ];
              }
            ];
            nodeSelector."kubernetes.io/hostname" = computeResources.instance;
            podSecurityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              runAsGroup = 65534;
              seccompProfile.type = "RuntimeDefault";
            };
            securityContext = {
              allowPrivilegeEscalation = false;
              readOnlyRootFilesystem = true;
              capabilities.drop = [ "ALL" ];
            };
            resources = {
              requests = {
                cpu = "10m";
                memory = "32Mi";
              };
              limits = {
                cpu = "100m";
                memory = "128Mi";
              };
            };
            rbac.create = true;
            serviceAccount.create = true;
            helperPod.resources = helperResources;
            configmap = {
              name = "local-path-config";
              # Publication waits for an explicitly provisioned leaf. The native
              # runtime hook, not this existence test, authorizes each writer.
              setup = ''
                set -eu
                test -d "$VOL_DIR"
              '';
              teardown = ''
                set -eu
                printf 'Retaining %s; deletion requires an explicit operator action.\n' "$VOL_DIR"
              '';
            };
          };
        };
        # The chart does not expose helper volumeMounts. Native local-path
        # reuses this named mount and retains readOnly while setting its path.
        resources.configMaps.local-path-config.data."helperPod.yaml" = lib.mkForce (
          builtins.toJSON {
            apiVersion = "v1";
            kind = "Pod";
            metadata.name = "helper-pod";
            spec = {
              automountServiceAccountToken = false;
              containers = [
                {
                  name = "helper-pod";
                  image = helperImage;
                  imagePullPolicy = "IfNotPresent";
                  resources = helperResources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = [ "ALL" ];
                  };
                  volumeMounts = [
                    {
                      name = "data";
                      mountPath = "/retained";
                      readOnly = true;
                    }
                  ];
                }
              ];
            };
          }
        );
      };
    };
}
