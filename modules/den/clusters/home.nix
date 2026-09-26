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
      radarr = route "radarr" "media" "radarr" 7878 "admin" "public" {
        "app.kubernetes.io/controller" = "main";
        "app.kubernetes.io/instance" = "radarr";
        "app.kubernetes.io/name" = "radarr";
      };
      sonarr = route "sonarr" "media" "sonarr" 8989 "admin" "public" {
        "app.kubernetes.io/controller" = "main";
        "app.kubernetes.io/instance" = "sonarr";
        "app.kubernetes.io/name" = "sonarr";
      };
      prowlarr = route "prowlarr" "media" "prowlarr" 9696 "admin" "public" {
        "app.kubernetes.io/controller" = "main";
        "app.kubernetes.io/instance" = "prowlarr";
        "app.kubernetes.io/name" = "prowlarr";
      };
      sabnzbd = route "sabnzbd" "media" "sabnzbd" 8080 "admin" "public" {
        "app.kubernetes.io/controller" = "main";
        "app.kubernetes.io/instance" = "sabnzbd";
        "app.kubernetes.io/name" = "sabnzbd";
      };
      requests = route "requests" "media" "seerr" 5055 "native" "public" {
        "app.kubernetes.io/controller" = "main";
        "app.kubernetes.io/instance" = "seerr";
        "app.kubernetes.io/name" = "seerr";
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
    # The existing Arr instances intentionally share the host-owned media
    # namespace. Private configuration remains on each instance's own claim.
    settings.kubernetes.services.media.radarr.radarr.sharedWritablePaths = [ "/data" ];
    settings.kubernetes.services.media.sonarr.sonarr.sharedWritablePaths = [ "/data" ];
  };

  den.aspects.prod-home = {
    includes = with den.aspects.kubernetes.services; [
      argocd
      cluster-dns
      retained-storage
      media
      jellyfin
      media
      gateway
      identity
    ];
  };
}
