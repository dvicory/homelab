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
      { cluster, computeResources, ... }:
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
        demandGroups = [
          {
            application = "prowlarr-storage";
            values = [
              {
                claim = "prowlarr";
                size = "5Gi";
              }
            ];
          }
          {
            application = "sabnzbd-storage";
            values = [
              {
                claim = "sabnzbd";
                size = "5Gi";
              }
            ];
          }
          {
            application = "seerr-storage";
            values = [
              {
                claim = "seerr";
                size = "5Gi";
              }
            ];
          }
          {
            application = "radarr-storage";
            values = map (cfg: {
              claim = cfg.state;
              size = "5Gi";
            }) (builtins.attrValues settings.radarr);
          }
          {
            application = "sonarr-storage";
            values = map (cfg: {
              claim = cfg.state;
              size = "5Gi";
            }) (builtins.attrValues settings.sonarr);
          }
        ];
        allClaims = lib.concatMap (group: map (demand: demand.claim) group.values) demandGroups;
        mkStorage =
          demand:
          let
            entry =
              assert lib.assertMsg (builtins.hasAttr demand.claim computeResources.retainedPaths)
                "Media state ${demand.claim} is not declared in computeResources.retainedPaths.";
              builtins.getAttr demand.claim computeResources.retainedPaths;
            claim = "media-${demand.claim}";
          in
          assert lib.assertMsg (!entry.readOnly) "Media claim ${claim} must be writable.";
          [
            {
              apiVersion = "v1";
              kind = "PersistentVolume";
              metadata = {
                name = claim;
                annotations = retained;
              };
              spec = {
                capacity.storage = demand.size;
                volumeMode = "Filesystem";
                accessModes = [ "ReadWriteOnce" ];
                persistentVolumeReclaimPolicy = "Retain";
                storageClassName = "";
                local.path = entry.guestPath;
                claimRef = {
                  namespace = "media";
                  name = claim;
                };
                nodeAffinity.required.nodeSelectorTerms = [
                  {
                    matchExpressions = [
                      {
                        key = "kubernetes.io/hostname";
                        operator = "In";
                        values = [ computeResources.instance ];
                      }
                    ];
                  }
                ];
              };
            }
            {
              apiVersion = "v1";
              kind = "PersistentVolumeClaim";
              metadata = {
                name = claim;
                namespace = "media";
                annotations = retained;
              };
              spec = {
                accessModes = [ "ReadWriteOnce" ];
                storageClassName = "";
                volumeName = claim;
                resources.requests.storage = demand.size;
              };
            }
          ];
        storageApplication = group: {
          namespace = "media";
          retained = true;
          objects = lib.concatMap mkStorage group.values;
        };
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
      assert lib.assertMsg (
        lib.unique allClaims == allClaims
      ) "Media retained storage claims must be unique.";
      {
        applications = {
          media-access = {
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
                  podSelector.matchLabels = {
                    "app.kubernetes.io/controller" = "main";
                    "app.kubernetes.io/instance" = "jellyfin";
                    "app.kubernetes.io/name" = "jellyfin";
                  };
                  policyTypes = [ "Ingress" ];
                  ingress = [
                    {
                      from = [
                        {
                          namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "media";
                          podSelector.matchLabels = {
                            "app.kubernetes.io/controller" = "main";
                            "app.kubernetes.io/instance" = "seerr";
                            "app.kubernetes.io/name" = "seerr";
                          };
                        }
                      ];
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
          media-storage = {
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
        }
        // lib.listToAttrs (
          map (group: {
            name = group.application;
            value = storageApplication group;
          }) demandGroups
        );
      };
  };
}
