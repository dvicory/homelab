{ lib, ... }:
{
  den.schema.cluster.includes = [
    {
      name = "nixidy/defaults";
      k8s-manifests =
        { cluster, ... }:
        { lib, ... }:
        {
          nixidy = {
            env = lib.mkDefault cluster.name;
            k8sVersion = cluster.k8sVersion;
            target = {
              repository = lib.mkDefault cluster.repository;
              branch = lib.mkDefault cluster.branch;
              rootPath = lib.mkDefault "./generated/manifests/${cluster.name}";
            };
            bootstrapManifest.enable = true;
            defaults.helm.extraOpts = [ "--kube-version" cluster.kubeVersion ];
            defaults.syncPolicy.autoSync = {
              enable = true;
              prune = true;
              selfHeal = true;
            };
          };
        };
    }
  ];
}
