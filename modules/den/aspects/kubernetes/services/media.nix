{ lib, den, ... }:
let
  retained = {
    "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
  };

in
{
  den.aspects.kubernetes.services.media = {
    includes = [
      den.aspects.kubernetes.services.radarr
      den.aspects.kubernetes.services.sonarr
      den.aspects.kubernetes.services.sabnzbd
      den.aspects.kubernetes.services.seerr
    ];
    k8s-manifests =
      { cluster, ... }:
      let
        settings = cluster.settings.kubernetes.services.media;
        instances = lib.concatLists [
          (lib.mapAttrsToList (_: cfg: cfg) settings.radarr)
          (lib.mapAttrsToList (_: cfg: cfg) settings.sonarr)
        ];
        stateKeys = map (cfg: cfg.state) instances;
        reserved = [
          "sabnzbd"
          "seerr"
        ];
      in
      assert lib.assertMsg (
        lib.unique stateKeys == stateKeys
      ) "Media instances must not share private retained state mappings.";
      assert lib.assertMsg (lib.all (
        key: !(builtins.elem key reserved)
      ) stateKeys) "Media instance state mappings may not reuse shared or fixed media claims.";
      {
        applications.media-access = {
          namespace = "media";
          objects = [
            {
              apiVersion = "networking.k8s.io/v1";
              kind = "NetworkPolicy";
              metadata = {
                name = "media-jellyfin-ingress";
                namespace = cluster.routes.jellyfin.namespace;
              };
              spec = {
                podSelector = { };
                policyTypes = [ "Ingress" ];
                ingress = [
                  {
                    from = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "media"; } ];
                    ports = [
                      {
                        protocol = "TCP";
                        port = cluster.routes.jellyfin.port;
                      }
                    ];
                  }
                ];
              };
            }
          ];
        };
        applications.media-storage = {
          namespace = "media";
          objects = [
            {
              apiVersion = "v1";
              kind = "Namespace";
              metadata = {
                name = "media";
                annotations = retained;
              };
            }
          ];
        };
      };
  };

}
