{ lib, ... }:
{
  den.schema.cluster.includes = [
    {
      name = "nixidy/defaults";
      k8s-manifests =
        { cluster, ... }:
        { lib, config, ... }:
        let
          managedProject = {
            apiVersion = "argoproj.io/v1alpha1";
            kind = "AppProject";
            metadata = {
              name = cluster.name;
              namespace = "argocd";
              annotations = {
                "argocd.argoproj.io/sync-wave" = "-4";
                "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
              };
            };
            spec = {
              sourceRepos = [ cluster.repository ];
              destinations =
                map
                  (namespace: {
                    inherit namespace;
                    server = config.nixidy.defaults.destination.server;
                  })
                  [
                    "argocd"
                    "kube-system"
                    "local-path-storage"
                    "gateway"
                    "identity"
                  ];
              clusterResourceWhitelist = [
                {
                  group = "";
                  kind = "Namespace";
                }
                {
                  group = "";
                  kind = "PersistentVolume";
                }
                {
                  group = "apiextensions.k8s.io";
                  kind = "CustomResourceDefinition";
                }
                {
                  group = "admissionregistration.k8s.io";
                  kind = "MutatingWebhookConfiguration";
                }
                {
                  group = "admissionregistration.k8s.io";
                  kind = "ValidatingAdmissionPolicy";
                }
                {
                  group = "admissionregistration.k8s.io";
                  kind = "ValidatingAdmissionPolicyBinding";
                }
                {
                  group = "rbac.authorization.k8s.io";
                  kind = "ClusterRole";
                }
                {
                  group = "rbac.authorization.k8s.io";
                  kind = "ClusterRoleBinding";
                }
                {
                  group = "storage.k8s.io";
                  kind = "StorageClass";
                }
                {
                  group = "gateway.networking.k8s.io";
                  kind = "GatewayClass";
                }
              ];
            };
          };
          bootstrapProject = {
            apiVersion = "argoproj.io/v1alpha1";
            kind = "AppProject";
            metadata = {
              name = "default";
              namespace = "argocd";
            };
            spec = {
              sourceRepos = [ cluster.repository ];
              destinations = [
                {
                  namespace = "argocd";
                  server = config.nixidy.defaults.destination.server;
                }
              ];
              clusterResourceWhitelist = [ ];
              namespaceResourceWhitelist = [
                {
                  group = "argoproj.io";
                  kind = "Application";
                }
                {
                  group = "argoproj.io";
                  kind = "AppProject";
                }
              ];
            };
          };
        in
        {
          nixidy = {
            env = lib.mkDefault cluster.name;
            k8sVersion = cluster.k8sVersion;
            target = {
              repository = lib.mkDefault cluster.repository;
              branch = lib.mkDefault cluster.branch;
              rootPath = lib.mkDefault "./generated/manifests/${cluster.name}";
            };
            appOfApps.project = "default";
            bootstrapManifest.enable = true;
            defaults.helm.extraOpts = [
              "--kube-version"
              cluster.kubeVersion
            ];
            applicationImports = [
              (
                { lib, config, ... }:
                {
                  options.retained = lib.mkEnableOption "keeping this Application's resources when it is deleted or pruned";
                  config = {
                    project = lib.mkDefault managedProject.metadata.name;
                    syncPolicy.retry = {
                      limit = lib.mkDefault 5;
                      backoff = {
                        duration = lib.mkDefault "5s";
                        factor = lib.mkDefault 2;
                        maxDuration = lib.mkDefault "1m";
                      };
                    };
                    syncPolicy.syncOptions = {
                      serverSideApply = lib.mkDefault true;
                      failOnSharedResource = lib.mkDefault true;
                    };
                    finalizer = lib.mkIf config.retained "non-cascading";
                    syncPolicy.autoSync.prune = lib.mkIf config.retained false;
                  };
                }
              )
            ];
            defaults.syncPolicy.autoSync = {
              enable = true;
              prune = true;
              selfHeal = true;
            };
            defaults.finalizer = "foreground";
          };

          applications.apps.objects = [ managedProject ];
          applications.__bootstrap.objects = [ bootstrapProject ];
        };
    }
  ];
}
