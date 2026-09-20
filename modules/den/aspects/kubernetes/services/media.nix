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
      den.aspects.kubernetes.services.prowlarr
      den.aspects.kubernetes.services.sabnzbd
      den.aspects.kubernetes.services.seerr
    ];
    k8s-manifests =
      { cluster, ... }:
      let
        settings = cluster.settings.kubernetes.services.media;
        instances = lib.concatLists [
          (builtins.attrValues settings.radarr)
          (builtins.attrValues settings.sonarr)
        ];
        stateKeys = map (cfg: cfg.state) instances;
        secretKeys = map (cfg: cfg.apiSecretKey) instances;
        roots = map (cfg: cfg.root) instances;
        categories = map (cfg: cfg.category) instances;
        rootOverlap =
          paths:
          if paths == [ ] then
            false
          else
            let
              path = builtins.head paths;
              rest = builtins.tail paths;
            in
            lib.any (
              other:
              path == other
              || lib.hasPrefix "${path}/" other
              || lib.hasPrefix "${other}/" path
            ) rest
            || rootOverlap rest;
        sharedDataDeclared = lib.all (
          cfg: lib.elem "/data" cfg.sharedWritablePaths
        ) instances;
        reserved = [
          "prowlarr"
          "sabnzbd"
          "seerr"
        ];
      in
      assert lib.assertMsg (
        lib.unique stateKeys == stateKeys
      ) "Media instances must not share private retained state mappings.";
      assert lib.assertMsg (
        lib.unique secretKeys == secretKeys
      ) "Media instances must not share private API credentials.";
      assert lib.assertMsg (
        !rootOverlap roots || sharedDataDeclared
      ) "Overlapping writable library roots require explicit shared writable path declaration.";
      assert lib.assertMsg (
        lib.unique categories == categories
      ) "Media instances must not share writable download categories.";
      assert lib.assertMsg (lib.all (
        key: !(builtins.elem key reserved)
      ) stateKeys) "Media instance state mappings may not reuse shared or fixed media claims.";
      assert lib.assertMsg sharedDataDeclared
        "Every media instance must declare its shared writable /data path.";
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
          retained = true;
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
