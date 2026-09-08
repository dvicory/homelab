{
  den,
  config,
  inputs,
  lib,
  ...
}:
let
  inherit (config.den.environments.prod) domain backupDomain;
  hosts = name: [
    "${name}.${domain}"
    "${name}.${backupDomain}"
  ];
  cluster = config.den.clusters.prod-home;
  kubeVersion = builtins.head (
    lib.splitString "+"
      inputs.nixpkgs.legacyPackages.${cluster.hostSystem}.k3s.version
  );
  route = key: namespace: service: port: auth: {
    inherit
      namespace
      service
      port
      auth
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
      jellyfin = route "jellyfin" "jellyfin" "jellyfin" 8096 "native";
      immich = route "immich" "immich" "immich-server" 2283 "native";
      radarr = route "radarr" "media" "radarr" 7878 "admin";
      sonarr = route "sonarr" "media" "sonarr" 8989 "admin";
      sabnzbd = route "sabnzbd" "media" "sabnzbd" 8080 "admin";
      requests = route "requests" "media" "seerr" 5055 "native";
      grafana = route "grafana" "monitoring" "monitoring-grafana" 80 "admin";
      argocd = route "argocd" "argocd" "argocd-server" 80 "admin";
      idm = (route "idm" "identity" "kanidm" 443 "native") // {
        backendTLS = true;
      };
    };
  };

  den.aspects.prod-home = {
    includes = with den.aspects.kubernetes.services; [
      argocd
      cluster-dns
      retained-storage
      jellyfin
      immich
      media
      monitoring
      gateway
      identity
    ];
  };
}
