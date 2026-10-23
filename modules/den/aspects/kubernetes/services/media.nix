{
  config,
  lib,
  den,
  ...
}:
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
        prowlarr = cluster.settings.kubernetes.services.prowlarr.integration;
        sabnzbd = cluster.settings.kubernetes.services.sabnzbd.integration;
        seerr = cluster.settings.kubernetes.services.seerr.integration;
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
        # Arr, Prowlarr and SABnzbd have no browser login of their own: the
        # Gateway's Kanidm sign-in is the only one. Anyone who reaches their
        # port can open the UI, and the Servarr UI hands out the API key. So
        # a route to one of them must be an administrator route whose Gateway
        # policy admits only the proxy, and media-ingress below admits only
        # the in-cluster clients each app is configured to serve.
        serviceName = kind: name: if name == kind then kind else "${kind}-${name}";
        # Ports match arr.nix.
        arrPorts = {
          radarr = 7878;
          sonarr = 8989;
        };
        arrInstances =
          lib.concatMap
            (
              kind:
              lib.mapAttrsToList (name: cfg: {
                service = serviceName kind name;
                port = arrPorts.${kind};
                inherit cfg;
              }) settings.${kind}
            )
            [
              "radarr"
              "sonarr"
            ];
        appPods = service: {
          "app.kubernetes.io/controller" = "main";
          "app.kubernetes.io/instance" = service;
          "app.kubernetes.io/name" = service;
        };
        # Pod labels of the in-cluster clients; the Job labels come from
        # media-configuration.nix.
        clients = {
          configarr."app.kubernetes.io/name" = "media-configarr";
          seerrHelper."app.kubernetes.io/name" = "media-config-seerr";
          seerr = appPods seerr.service;
          prowlarr = appPods prowlarr.service;
        };
        arrClients = map (instance: appPods instance.service) arrInstances;
        # Who calls whom, from the media configuration:
        # - Configarr writes every Arr instance and Prowlarr.
        # - Prowlarr pushes indexers to every Arr instance (fullSync).
        # - Seerr and its helper use the Arr instances that have a Seerr role.
        # - Every Arr instance searches through Prowlarr and sends downloads
        #   to SABnzbd.
        loginlessApps =
          map (instance: {
            inherit (instance) service port;
            consumers = [
              clients.configarr
              clients.prowlarr
            ]
            ++ lib.optionals (instance.cfg.role != null) [
              clients.seerr
              clients.seerrHelper
            ];
          }) arrInstances
          ++ [
            {
              inherit (prowlarr) service port;
              consumers = [ clients.configarr ] ++ arrClients;
            }
            {
              inherit (sabnzbd) service port;
              consumers = arrClients;
            }
          ];
        loginlessServices = map (app: app.service) loginlessApps;
        openLoginlessRoutes = builtins.attrNames (
          lib.filterAttrs (
            _: route:
            route.namespace == "media"
            && lib.elem route.service loginlessServices
            && (route.auth != "admin" || route.sameNamespaceIngress)
          ) cluster.routes
        );
        ingressPolicy = app: {
          apiVersion = "networking.k8s.io/v1";
          kind = "NetworkPolicy";
          metadata = {
            name = "media-${app.service}-ingress";
            namespace = "media";
          };
          spec = {
            podSelector.matchLabels = appPods app.service;
            policyTypes = [ "Ingress" ];
            ingress = [
              {
                from = map (labels: { podSelector.matchLabels = labels; }) app.consumers;
                ports = [
                  {
                    protocol = "TCP";
                    inherit (app) port;
                  }
                ];
              }
            ];
          };
        };
        reserved = [
          "prowlarr"
          "sabnzbd"
          "seerr"
        ];
        reservedSecretKeys = lib.concatMap (
          name:
          map (secret: secret.key) (
            builtins.attrValues (
              (config.den.aspects.kubernetes.services.${name}.compute-resources { inherit cluster; })
              .runtimeSecrets
            )
          )
        ) reserved;
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
          annotations."argocd.argoproj.io/sync-wave" = "0";
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
      assert lib.assertMsg (lib.all (key: !(lib.elem key reservedSecretKeys))
        secretKeys
      ) "Media instance API credentials may not reuse credentials owned by another media service.";
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
      assert lib.assertMsg (openLoginlessRoutes == [ ])
        "Routes to media apps without their own login must use auth = \"admin\" and sameNamespaceIngress = false: ${lib.concatStringsSep ", " openLoginlessRoutes}";
      assert lib.assertMsg (
        lib.unique allClaims == allClaims
      ) "Media retained storage claims must be unique.";
      {
        applications = {
          media-access = {
            namespace = cluster.routes.jellyfin.namespace;
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
                          namespaceSelector.matchLabels."kubernetes.io/metadata.name" = seerr.namespace;
                          podSelector.matchLabels = clients.seerr;
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
          # Selecting each app's pods also refuses every other in-cluster
          # client, including other pods in media. Wave 0 puts the policies
          # in place before the wave-1 workloads start.
          media-ingress = {
            namespace = "media";
            annotations."argocd.argoproj.io/sync-wave" = "0";
            objects = map ingressPolicy loginlessApps;
          };
          media-storage = {
            namespace = "media";
            annotations."argocd.argoproj.io/sync-wave" = "0";
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
