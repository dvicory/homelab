{ lib, ... }:
{
  den.schema.cluster.includes = [
    {
      name = "nixidy/defaults";
      k8s-manifests =
        { cluster, ... }:
        { lib, config, ... }:
        let
          project = {
            apiVersion = "argoproj.io/v1alpha1";
            kind = "AppProject";
            metadata = {
              name = config.nixidy.appOfApps.project;
              namespace = "argocd";
              annotations."argocd.argoproj.io/sync-wave" = "-1";
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
                  group = "apiextensions.k8s.io";
                  kind = "CustomResourceDefinition";
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
            appOfApps.project = lib.mkDefault cluster.name;
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
                    project = lib.mkDefault cluster.name;
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

          applications.apps.objects = [ project ];
          applications.__bootstrap.objects = [ project ];
        };
    }
  ];
}
