{ den, ... }:
let
  domain = "plus2.danielvicory.dev";
  backupDomain = "backup.${domain}";
  hosts = name: [ "${name}.${domain}" "${name}.${backupDomain}" ];
  route = key: namespace: service: port: auth: {
    inherit namespace service port auth;
    hostnames = hosts key;
    pathPrefix = "/";
    backendTLS = service == "kanidm";
  };
in
{
  den.clusters.prod-home = {
    environment = "prod";
    nodeName = "compute-1";
    storageRoot = "/srv/platform";
    inherit domain backupDomain;
    kubeVersion = "1.35.8";
    k8sVersion = "1.35";
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
      idm = route "idm" "identity" "kanidm" 443 "native";
    };
  };

  den.aspects.prod-home = {
    includes = with den.aspects.kubernetes.services; [
      argocd
      jellyfin
      immich
      media
      monitoring
      gateway
      identity
    ];
  };
}
