{
  den,
  config,
  inputs,
  lib,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  inherit (config.den.environments.${cluster.environment}) domain backupDomain;
  hosts = name: [
    "${name}.${domain}"
    "${name}.${backupDomain}"
  ];
  kubeVersion = builtins.head (
    lib.splitString "+" inputs.nixpkgs.legacyPackages.${cluster.hostSystem}.k3s.version
  );
  route = key: namespace: service: port: auth: backendPodSelector: {
    inherit
      namespace
      service
      port
      auth
      backendPodSelector
      ;
    hostnames = hosts key;
    pathPrefix = "/";
    backendTLS = false;
  };
in
{
  den.clusters.prod-home = {
    environment = "prod";
    hostSystem = "x86_64-linux";
    hostName = "hvn-hyp1";
    inherit kubeVersion;
    k8sVersion = lib.versions.majorMinor kubeVersion;
    repository = "https://github.com/dvicory/homelab.git";
    branch = "main";
    ingress = {
      nodePort = 30443;
      trustedProxyCIDRs = [ ];
    };
    routes = {
      argocd = route "argocd" "argocd" "argocd-server" 80 "admin" {
        "app.kubernetes.io/instance" = "argocd";
        "app.kubernetes.io/name" = "argocd-server";
      };
      idm =
        (route "idm" "identity" "kanidm" 443 "native" {
          "app.kubernetes.io/name" = "kanidm";
        })
        // {
          backendTLS = true;
        };
    };
  };

  den.aspects.prod-home = {
    includes = with den.aspects.kubernetes.services; [
      argocd
      cluster-dns
      retained-storage
      gateway
      identity
    ];
  };
}
