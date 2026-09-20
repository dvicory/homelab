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
        categories = map (cfg: cfg.category) instances;
        unapprovedRootOverlap =
          owners:
          if owners == [ ] then
            false
          else
            let
              owner = builtins.head owners;
              rest = builtins.tail owners;
            in
            lib.any (
              other:
              (
                owner.root == other.root
                || lib.hasPrefix "${owner.root}/" other.root
                || lib.hasPrefix "${other.root}/" owner.root
              )
              && !(lib.any (
                shared:
                shared != "/data"
                && lib.elem shared other.sharedWritablePaths
                && lib.all (root: root == shared || lib.hasPrefix "${shared}/" root) [
                  owner.root
                  other.root
                ]
              ) owner.sharedWritablePaths)
            ) rest
            || unapprovedRootOverlap rest;
        sharedDataDeclared = lib.all (cfg: lib.elem "/data" cfg.sharedWritablePaths) instances;
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
        !unapprovedRootOverlap instances
      ) "Overlapping library roots require both instances to grant a common library path below /data.";
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
