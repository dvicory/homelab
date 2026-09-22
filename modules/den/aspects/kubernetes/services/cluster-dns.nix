{ lib, ... }:
{
  den.aspects.kubernetes.services.cluster-dns.k8s-manifests = {
    applications.cluster-dns = {
      namespace = "kube-system";
      annotations."argocd.argoproj.io/sync-wave" = "-1";
      createNamespace = false;
      # Services contribute individual *.override keys, not competing objects.
      resources.configMaps.coredns-custom.data = lib.mkDefault { };
    };
  };
}
