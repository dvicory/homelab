{ lib, ... }:
{
  den.aspects.kubernetes.services.cluster-dns.k8s-manifests = {
    applications.cluster-dns = {
      namespace = "kube-system";
      createNamespace = false;
      # Services contribute individual *.override keys, not competing objects.
      resources.configMaps.coredns-custom.data = lib.mkDefault { };
    };
  };
}
