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
  route = key: namespace: service: port: auth: exposure: backendPodSelector: {
    inherit
      namespace
      service
      port
      auth
      exposure
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
      mode = "direct";
      nodePort = 30443;
      trustedProxyCIDRs = [ ];
    };
    settings.kubernetes.services.identity.phase = "initial";
    routes = {
      argocd = route "argocd" "argocd" "argocd-server" 80 "admin" "public" {
        "app.kubernetes.io/instance" = "argocd";
        "app.kubernetes.io/name" = "argocd-server";
      };
      jellyfin =
        (route "jellyfin" "jellyfin" "jellyfin" 8096 "native" "private" {
          "app.kubernetes.io/controller" = "main";
          "app.kubernetes.io/instance" = "jellyfin";
          "app.kubernetes.io/name" = "jellyfin";
        })
        // {
          timeouts = {
            request = "0s";
            backendRequest = "0s";
          };
        };
      idm =
        (route "idm" "identity" "kanidm" 443 "native" "public" {
          "app.kubernetes.io/name" = "kanidm";
        })
        // {
          backendTLS = true;
          backendHostname = builtins.head (hosts "idm");
        };
    };
  };

  den.aspects.prod-home = {
    includes = with den.aspects.kubernetes.services; [
      argocd
      cluster-dns
      retained-storage
      media
      jellyfin
      gateway
      identity
    ];
  };
}
