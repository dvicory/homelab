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
  route = key: auth: exposure: {
    inherit auth exposure;
    hostnames = hosts key;
  };
in
{
  den.clusters.prod-home = {
    environment = "prod";
    inherit domain backupDomain;
    hostSystem = "x86_64-linux";
    hostName = "hvn-hyp1";
    inherit kubeVersion;
    k8sVersion = lib.versions.majorMinor kubeVersion;
    repository = "https://github.com/dvicory/homelab.git";
    branch = "main";
    ingress = {
      nodePort = 30443;
      public = null;
    };
    settings.kubernetes.services.identity.phase = "normal";
    settings.kubernetes.services.seerr.phase = "ready";
    settings.kubernetes.services.homarr.phase = "initial";
    routes = {
      home = route "home" "native" "public" // {
        sameNamespaceIngress = false;
        # Homarr owns admission even while first-run onboarding is private.
        manageBackendIngress = false;
      };
      argocd = route "argocd" "admin" "public";
      grafana = route "grafana" "admin" "public" // {
        # Nothing in the monitoring namespace connects to Grafana.
        sameNamespaceIngress = false;
      };
      # These apps have no login of their own. Media owns in-cluster admission;
      # their Gateway policies admit only the Gateway proxy.
      radarr = route "radarr" "admin" "public" // {
        sameNamespaceIngress = false;
      };
      sonarr = route "sonarr" "admin" "public" // {
        sameNamespaceIngress = false;
      };
      prowlarr = route "prowlarr" "admin" "public" // {
        sameNamespaceIngress = false;
      };
      sabnzbd = route "sabnzbd" "admin" "public" // {
        sameNamespaceIngress = false;
      };
      requests = route "requests" "native" "public";
      jellyfin = route "jellyfin" "native" "private";
      idm = {
        hostnames = [ "id.bzfx.net" ];
        auth = "native";
        exposure = "public";
        # Kanidm owns port-specific HTTPS and LDAPS admission.
        manageBackendIngress = false;
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
      cert-manager
      cluster-dns
      network-policy
      retained-storage
      media
      jellyfin
      homarr
      gateway
      identity
      monitoring
    ];
  };
}
