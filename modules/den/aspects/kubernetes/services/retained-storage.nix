{ ... }:
let
  namespace = "local-path-storage";
  storageClassName = "retained-local";
  provisionerName = "rancher.io/local-path";
  chartVersion = "0.0.34";
  chartHash = "sha256-vkjwkF+QvTZ/PRaOanyXrXfYCSe/wBcRatga0SgDel0=";
  protect = {
    "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
  };
in
{
  den.aspects.kubernetes.services.retained-storage.compute-resources.retainedPaths.kubernetes-volumes =
    {
      uid = 0;
      gid = 0;
      mode = "0700";
    };
  den.aspects.kubernetes.services.retained-storage.k8s-manifests =
    { compute, lib, ... }:
    let
      retained = compute.retainedPaths."kubernetes-volumes";
      chart = lib.helm.downloadHelmChart {
        repo = "oci://ghcr.io/rancher/local-path-provisioner/charts";
        chart = "local-path-provisioner";
        version = chartVersion;
        inherit chartHash;
      };
      nodeTopology = [
        {
          matchLabelExpressions = [
            {
              key = "kubernetes.io/hostname";
              values = [ compute.instance ];
            }
          ];
        }
      ];
      controllerResources = {
        requests = {
          cpu = "10m";
          memory = "32Mi";
        };
        limits = {
          cpu = "100m";
          memory = "128Mi";
        };
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
    in
    assert lib.assertMsg (
      retained.uid == 0 && retained.gid == 0 && retained.mode == "0700" && !retained.readOnly
    ) "compute.retainedPaths.kubernetes-volumes must be a writable root-owned parent with mode 0700";
    {
      applications.retained-storage = {
        inherit namespace;
        createNamespace = false;
        finalizer = "non-cascading";
        syncPolicy.autoSync = {
          enable = true;
          prune = false;
          selfHeal = true;
        };
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
            apiVersion = "storage.k8s.io/v1";
            kind = "StorageClass";
            metadata = {
              name = storageClassName;
              annotations = protect // {
                "storageclass.kubernetes.io/is-default-class" = "true";
                defaultVolumeType = "local";
              };
            };
            provisioner = provisionerName;
            volumeBindingMode = "WaitForFirstConsumer";
            reclaimPolicy = "Retain";
            allowVolumeExpansion = false;
            allowedTopologies = nodeTopology;
          }
        ];
      };

      applications.local-path-provisioner = {
        inherit namespace;
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
              provisionerName = provisionerName;
            };
            # No DEFAULT_PATH_FOR_NON_LISTED_NODES entry means unknown nodes
            # fail closed instead of receiving a substitute backing path.
            nodePathMap = [
              {
                node = compute.instance;
                paths = [ retained.guestPath ];
              }
            ];
            nodeSelector."kubernetes.io/hostname" = compute.instance;
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
            resources = controllerResources;
            rbac.create = true;
            serviceAccount.create = true;
            helperPod.resources = helperResources;
            configmap = {
              name = "local-path-config";
              setup = ''
                set -eu
                umask 077
                mkdir -m 0700 -p "$VOL_DIR"
              '';
              teardown = ''
                set -eu
                rm -rf "$VOL_DIR"
              '';
            };
          };
        };
      };
    };
}
