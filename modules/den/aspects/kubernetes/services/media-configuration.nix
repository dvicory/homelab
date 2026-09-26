{
  inputs,
  lib,
  den,
  ...
}:
{
  den.aspects.kubernetes.services.media = {
    settings.configurationSecret = lib.mkOption {
      type = lib.types.str;
      default = "media-runtime";
      description = ''
        Runtime Secret in media containing native Arr API keys and SABnzbd
        credentials. Jellyfin's administrator credential remains owned by
        Jellyfin in its own namespace.
      '';
    };
    includes = [
      den.aspects.kubernetes.services.media.configuration
    ];
  };

  den.aspects.kubernetes.services.media.configuration.k8s-manifests =
    { cluster, ... }:
    let
      settings = cluster.settings.kubernetes.services.media;
      routePrefix =
        route:
        if route == null || route.pathPrefix == "/" then "" else lib.removeSuffix "/" route.pathPrefix;
      factFor =
        {
          namespace,
          service,
          port,
          routeKey,
          apiSecretKey ? null,
        }:
        let
          route = if routeKey == null then null else builtins.getAttr routeKey cluster.routes;
          prefix = routePrefix route;
        in
        {
          inherit
            namespace
            service
            port
            routeKey
            apiSecretKey
            ;
          routePrefix = prefix;
          externalUrl = if route == null then null else "https://${builtins.head route.hostnames}${prefix}";
        };
      routeFact =
        routeKey:
        let
          route = builtins.getAttr routeKey cluster.routes;
        in
        factFor {
          inherit routeKey;
          inherit (route) namespace service port;
        };
      arrFacts =
        kind: port:
        lib.mapAttrs (
          instanceName: cfg:
          factFor {
            namespace = "media";
            service = if instanceName == kind then kind else "${kind}-${instanceName}";
            inherit port;
            inherit (cfg) routeKey apiSecretKey;
          }
        ) settings.${kind};
      services = {
        prowlarr = routeFact "prowlarr" // {
          apiSecretKey = "PROWLARR_API_KEY";
        };
        sabnzbd = routeFact "sabnzbd";
        seerr = routeFact "requests";
        radarr = arrFacts "radarr" 7878;
        sonarr = arrFacts "sonarr" 8989;
      };
      apps = {
        jellyfin = cluster.settings.kubernetes.services.jellyfin.integration;
        inherit (services) prowlarr sabnzbd seerr;
      };
      images = builtins.mapAttrs (_: image: "${image.repository}:${image.tag}@${image.digest}") {
        configarr = {
          repository = "docker.io/configarr/configarr";
          tag = "1.30.2";
          digest = "sha256:ec585b6d2530f6090ee26fdcc9701f279666c24dc96c9087208e88ec867c2416";
        };
        node = {
          repository = "docker.io/library/node";
          tag = "22.14.0-bookworm-slim";
          digest = "sha256:1c18d9ab3af4585870b92e4dbc5cac5a0dc77dd13df1a5905cea89fc720eb05b";
        };
      };
      trashRevision = "04e692c8926f6b9736943afcd9b505bad29f5e54";
      prowlarrSecretKey = services.prowlarr.apiSecretKey;
      retained = {
        "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
      };

      yaml = builtins.toJSON;
      endpoint =
        fact: "http://${fact.service}.${fact.namespace}.svc:${toString fact.port}${fact.routePrefix}";
      instancePolicy =
        {
          kind,
          instanceName,
          cfg,
          ...
        }:
        let
          fact = services.${kind}.${instanceName};
        in
        {
          url = endpoint fact;
          externalUrl = fact.externalUrl;
          root = cfg.root;
          category = cfg.category;
          profile = cfg.profile;
          apiSecretKey = cfg.apiSecretKey;
        };

      profileTemplate =
        profile:
        let
          quality = lib.removePrefix "WEB-" profile;
        in
        ''
          quality_profiles:
            - name: ${yaml profile}
              upgrade:
                allowed: true
                until_quality: "WEB ${quality}"
                until_score: 10000
                min_format_score: 1
              min_format_score: 0
              qualities:
                - name: "WEB ${quality}"
                  qualities:
                    - "WEBDL-${quality}"
                    - "WEBRip-${quality}"
        '';

      instanceYaml =
        {
          cluster,
          kind,
          instances,
        }:
        lib.concatMapStringsSep "\n" (
          instanceName:
          let
            cfg = builtins.getAttr instanceName instances;
            desired = instancePolicy {
              inherit
                cluster
                kind
                instanceName
                cfg
                ;
            };
            categoryField = if kind == "radarr" then "movie_category" else "tv_category";
          in
          ''
            ${yaml instanceName}:
              base_url: ${yaml desired.url}
              api_key: !env ${cfg.apiSecretKey}
              quality_definition:
                type: ${if kind == "radarr" then "movie" else "series"}
              include:
                - template: ${yaml "media-${kind}-${instanceName}"}
              download_clients:
                update_password: true
                data:
                  - name: "SABnzbd (Homelab)"
                    type: "Sabnzbd"
                    enable: true
                    priority: 1
                    remove_completed_downloads: true
                    remove_failed_downloads: true
                    fields:
                      host: ${yaml "${apps.sabnzbd.service}.${apps.sabnzbd.namespace}.svc"}
                      port: ${toString apps.sabnzbd.port}
                      use_ssl: false
                      url_base: ""
                      api_key: !env SABNZBD_API_KEY
                      username: !env SABNZBD_USERNAME
                      password: !env SABNZBD_PASSWORD
                      ${categoryField}: ${yaml cfg.category}
          ''
        ) (builtins.attrNames instances);

      rootsPolicy =
        cluster:
        let
          settings = cluster.settings.kubernetes.services.media;
          make =
            kind: instances:
            lib.mapAttrs (
              instanceName: cfg:
              instancePolicy {
                inherit
                  cluster
                  kind
                  instanceName
                  cfg
                  ;
              }
            ) instances;
        in
        {
          arr = {
            radarr = make "radarr" settings.radarr;
            sonarr = make "sonarr" settings.sonarr;
          };
        };

      seerrPolicy =
        cluster: kind: instances:
        let
          selected = lib.filter (name: instances.${name}.seerrDefault) (builtins.attrNames instances);
        in
        assert lib.assertMsg (builtins.length selected == 1)
          "Exactly one ${kind} instance must have seerrDefault = true for Seerr.";
        let
          name = builtins.head selected;
          cfg = instances.${name};
        in
        (instancePolicy {
          inherit cluster kind cfg;
          instanceName = name;
        })
        // {
          inherit name;
        };

      configarrConfig =
        cluster:
        let
          settings = cluster.settings.kubernetes.services.media;
          nestedInstances =
            kind:
            lib.concatMapStringsSep "\n" (line: "  ${line}") (
              lib.splitString "\n" (instanceYaml {
                inherit cluster kind;
                instances = settings.${kind};
              })
            );
        in
        ''
          # Configarr v1.30.2: the Git URLs intentionally point at detached local
          # repositories seeded from the selected TRaSH revision before each run.
          trashGuideUrl: "file:///app/repos/trash-guides"
          trashRevision: HEAD
          recyclarrConfigUrl: "file:///app/repos/recyclarr-config"
          recyclarrRevision: HEAD
          localConfigTemplatesPath: "/app/templates"
          telemetry: false
          sonarr:
          ${nestedInstances "sonarr"}
          radarr:
          ${nestedInstances "radarr"}
        '';

      policyConfig =
        cluster:
        let
          settings = cluster.settings.kubernetes.services.media;
          jellyfinRoute = cluster.routes.jellyfin;
          prowlarrUrl = endpoint apps.prowlarr;
        in
        {
          roots = builtins.toJSON (rootsPolicy cluster);
          prowlarr = builtins.toJSON {
            prowlarr = {
              url = prowlarrUrl;
              apiSecretKey = prowlarrSecretKey;
            };
            applications =
              lib.concatMap
                (
                  kind:
                  lib.mapAttrsToList (
                    instanceName: cfg:
                    let
                      desired = instancePolicy {
                        inherit
                          cluster
                          kind
                          instanceName
                          cfg
                          ;
                      };
                    in
                    {
                      name = "homelab-${services.${kind}.${instanceName}.service}";
                      implementation = if kind == "radarr" then "Radarr" else "Sonarr";
                      baseUrl = desired.url;
                      apiSecretKey = cfg.apiSecretKey;
                      syncLevel = "fullSync";
                      inherit prowlarrUrl;
                    }
                  ) settings.${kind}
                )
                [
                  "radarr"
                  "sonarr"
                ];
          };
          seerr = builtins.toJSON {
            arr = {
              radarr = seerrPolicy cluster "radarr" settings.radarr;
              sonarr = seerrPolicy cluster "sonarr" settings.sonarr;
            };
            seerr = {
              url = endpoint apps.seerr;
              applicationUrl = apps.seerr.externalUrl;
            };
            jellyfin = {
              ip = apps.jellyfin.host;
              port = apps.jellyfin.port;
              useSsl = jellyfinRoute.backendTLS;
              urlBase = routePrefix jellyfinRoute;
              externalHostname = "https://${builtins.head jellyfinRoute.hostnames}${routePrefix jellyfinRoute}";
              username = apps.jellyfin.administrator;
              library = apps.jellyfin.moviesLibrary;
              secret = apps.jellyfin.adminSecret;
            };
            # Keep this value visible in the evaluated policy: SAB is configured by
            # its own native INI initializer, not by Seerr or the Arr reconciler.
            sab = {
              host = "${apps.sabnzbd.service}.${apps.sabnzbd.namespace}.svc";
              port = apps.sabnzbd.port;
            };
          };
          inherit trashRevision;
        };

      templates =
        cluster:
        let
          settings = cluster.settings.kubernetes.services.media;
          make =
            kind: instances:
            lib.listToAttrs (
              lib.mapAttrsToList (name: cfg: {
                name = "media-${kind}-${name}.yml";
                value = profileTemplate cfg.profile;
              }) instances
            );
        in
        (make "radarr" settings.radarr) // (make "sonarr" settings.sonarr);

      trashInputs = {
        "radarr-movie.json" = builtins.readFile (inputs.self + "/assets/media-policy/radarr-movie.json");
        "sonarr-series.json" = builtins.readFile (inputs.self + "/assets/media-policy/sonarr-series.json");
        "sonarr-anime.json" = builtins.readFile (inputs.self + "/assets/media-policy/sonarr-anime.json");
        "conflicts.json" = builtins.readFile (inputs.self + "/assets/media-policy/conflicts.json");
      };

      seedPolicy = ''
        set -eu
        for repo in trash-guides recyclarr-config; do
          root="/app/repos/$repo"
          rm -rf "$root"
          mkdir -p "$root"
        done
        trash="/app/repos/trash-guides/docs/json"
        for app in radarr sonarr; do
          for directory in cf cf-groups naming quality-profiles quality-size; do
            mkdir -p "$trash/$app/$directory"
          done
          for directory in custom-formats quality-definitions quality-profiles; do
            mkdir -p "/app/repos/recyclarr-config/$app/includes/$directory"
          done
        done
        cp /seed/radarr-movie.json "$trash/radarr/quality-size/movie.json"
        cp /seed/sonarr-series.json "$trash/sonarr/quality-size/series.json"
        cp /seed/sonarr-anime.json "$trash/sonarr/quality-size/anime.json"
        cp /seed/conflicts.json "$trash/radarr/conflicts.json"
        cp /seed/conflicts.json "$trash/sonarr/conflicts.json"
        printf '%s\n' '${trashRevision}' > /app/repos/trash-guides/TRASH-GUIDES-REVISION
        for repo in trash-guides recyclarr-config; do
          git -C "/app/repos/$repo" init -q
          git -C "/app/repos/$repo" config user.email "media-policy@localhost"
          git -C "/app/repos/$repo" config user.name "media-policy"
          git -C "/app/repos/$repo" add .
          git -C "/app/repos/$repo" commit --allow-empty -qm "Pinned offline media policy inputs"
          git -C "/app/repos/$repo" checkout --detach -q HEAD
        done
      '';

      secretEnv = secretName: key: {
        name = key;
        valueFrom.secretKeyRef = {
          name = secretName;
          inherit key;
        };
      };

      baseJob =
        {
          name,
          image,
          command,
          mounts,
          volumes,
          secretName,
          secretKeys,
          serviceAccountName ? "default",
          env ? [ ],
        }:
        {
          backoffLimit = 6;
          activeDeadlineSeconds = 900;
          template = {
            metadata.labels."app.kubernetes.io/name" = name;
            spec = {
              restartPolicy = "OnFailure";
              automountServiceAccountToken = false;
              inherit serviceAccountName;
              securityContext = {
                runAsUser = 1000;
                runAsGroup = 1000;
                runAsNonRoot = true;
                fsGroup = 1000;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                {
                  name = "configure";
                  inherit image command env;
                  resources = {
                    requests = {
                      cpu = "25m";
                      memory = "64Mi";
                    };
                    limits = {
                      cpu = "500m";
                      memory = "256Mi";
                    };
                  };
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = [ "ALL" ];
                  };
                  volumeMounts = mounts;
                }
              ];
              volumes = volumes ++ [
                {
                  name = "secrets";
                  projected = {
                    defaultMode = 288;
                    sources = [
                      {
                        secret = {
                          name = secretName;
                          items = map (key: {
                            inherit key;
                            path = key;
                          }) secretKeys;
                        };
                      }
                    ];
                  };
                }
              ];
            };
          };
        };

      hook = name: wave: spec: {
        apiVersion = "batch/v1";
        kind = "Job";
        metadata = {
          inherit name;
          namespace = "media";
          annotations = {
            "argocd.argoproj.io/hook" = "PostSync";
            "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
            "argocd.argoproj.io/sync-wave" = toString wave;
          };
        };
        inherit spec;
      };

      secretName = cluster.settings.kubernetes.services.media.configurationSecret;
      arrSecretKeys = lib.unique (
        map (cfg: cfg.apiSecretKey) (
          builtins.attrValues cluster.settings.kubernetes.services.media.radarr
          ++ builtins.attrValues cluster.settings.kubernetes.services.media.sonarr
        )
      );
      generatedPolicy = policyConfig cluster;
      configurationData = {
        "config.yml" = configarrConfig cluster;
        "roots.json" = generatedPolicy.roots;
        "prowlarr.json" = generatedPolicy.prowlarr;
        "seerr.json" = generatedPolicy.seerr;
        "trash-guide-revision" = generatedPolicy.trashRevision;
      };
      templateFiles = templates cluster;
      rootJob = baseJob {
        name = "media-config-roots";
        image = images.node;
        command = [
          "node"
          "/configuration/roots.mjs"
        ];
        secretName = secretName;
        secretKeys = arrSecretKeys;
        mounts = [
          {
            name = "configuration";
            mountPath = "/configuration";
            readOnly = true;
          }
          {
            name = "secrets";
            mountPath = "/secrets";
            readOnly = true;
          }
        ];
        volumes = [
          {
            name = "configuration";
            configMap = {
              name = "media-configuration";
            };
          }
        ];
      };
      prowlarrJob = baseJob {
        name = "media-config-prowlarr";
        image = images.node;
        command = [
          "node"
          "/configuration/prowlarr.mjs"
        ];
        secretName = secretName;
        secretKeys = arrSecretKeys ++ [ prowlarrSecretKey ];
        mounts = [
          {
            name = "configuration";
            mountPath = "/configuration";
            readOnly = true;
          }
          {
            name = "secrets";
            mountPath = "/secrets";
            readOnly = true;
          }
        ];
        volumes = [
          {
            name = "configuration";
            configMap = {
              name = "media-configuration";
            };
          }
        ];
      };
      seerrJob = baseJob {
        name = "media-config-seerr";
        image = images.node;
        command = [
          "node"
          "/configuration/seerr.mjs"
        ];
        secretName = secretName;
        secretKeys = arrSecretKeys;
        serviceAccountName = "media-config-seerr";
        env = [
          {
            name = "NODE_EXTRA_CA_CERTS";
            value = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt";
          }
        ];
        mounts = [
          {
            name = "configuration";
            mountPath = "/configuration";
            readOnly = true;
          }
          {
            name = "secrets";
            mountPath = "/secrets";
            readOnly = true;
          }
          {
            name = "kubernetes-api";
            mountPath = "/var/run/secrets/kubernetes.io/serviceaccount";
            readOnly = true;
          }
        ];
        volumes = [
          {
            name = "configuration";
            configMap = {
              name = "media-configuration";
            };
          }
          {
            name = "kubernetes-api";
            projected = {
              defaultMode = 288;
              sources = [
                {
                  serviceAccountToken = {
                    path = "token";
                    expirationSeconds = 600;
                  };
                }
                {
                  configMap = {
                    name = "kube-root-ca.crt";
                    items = [
                      {
                        key = "ca.crt";
                        path = "ca.crt";
                      }
                    ];
                  };
                }
              ];
            };
          }
        ];
      };
      configarrJob = {
        backoffLimit = 6;
        activeDeadlineSeconds = 900;
        template = {
          metadata.labels."app.kubernetes.io/name" = "media-configarr";
          spec = {
            restartPolicy = "OnFailure";
            automountServiceAccountToken = false;
            securityContext = {
              runAsUser = 1000;
              runAsGroup = 1000;
              runAsNonRoot = true;
              fsGroup = 1000;
              seccompProfile.type = "RuntimeDefault";
            };
            initContainers = [
              {
                name = "seed-policy";
                image = images.configarr;
                command = [
                  "/bin/sh"
                  "-ec"
                  seedPolicy
                ];
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = [ "ALL" ];
                };
                resources = {
                  requests = {
                    cpu = "10m";
                    memory = "32Mi";
                  };
                  limits = {
                    cpu = "250m";
                    memory = "128Mi";
                  };
                };
                volumeMounts = [
                  {
                    name = "policy-inputs";
                    mountPath = "/seed";
                    readOnly = true;
                  }
                  {
                    name = "repos";
                    mountPath = "/app/repos";
                  }
                ];
              }
            ];
            containers = [
              {
                name = "configarr";
                image = images.configarr;
                env = [
                  {
                    name = "ROOT_PATH";
                    value = "/app";
                  }
                  {
                    name = "CONFIG_LOCATION";
                    value = "/app/config/config.yml";
                  }
                  {
                    name = "CUSTOM_REPO_ROOT";
                    value = "/app/repos";
                  }
                  {
                    name = "STOP_ON_ERROR";
                    value = "true";
                  }
                  {
                    name = "LOG_LEVEL";
                    value = "warn";
                  }
                ]
                ++ map (secretEnv secretName) (
                  lib.unique (
                    map (cfg: cfg.apiSecretKey) (
                      builtins.attrValues cluster.settings.kubernetes.services.media.radarr
                      ++ builtins.attrValues cluster.settings.kubernetes.services.media.sonarr
                    )
                  )
                  ++ [
                    "SABNZBD_API_KEY"
                    "SABNZBD_USERNAME"
                    "SABNZBD_PASSWORD"
                  ]
                );
                resources = {
                  requests = {
                    cpu = "25m";
                    memory = "64Mi";
                  };
                  limits = {
                    cpu = "1";
                    memory = "512Mi";
                  };
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = [ "ALL" ];
                };
                volumeMounts = [
                  {
                    name = "configuration";
                    mountPath = "/app/config";
                    readOnly = true;
                  }
                  {
                    name = "templates";
                    mountPath = "/app/templates";
                    readOnly = true;
                  }
                  {
                    name = "repos";
                    mountPath = "/app/repos";
                  }
                ];
              }
            ];
            volumes = [
              {
                name = "configuration";
                configMap = {
                  name = "media-configuration";
                  items = [
                    {
                      key = "config.yml";
                      path = "config.yml";
                    }
                  ];
                };
              }
              {
                name = "templates";
                configMap = {
                  name = "media-configarr-templates";
                };
              }
              {
                name = "policy-inputs";
                configMap = {
                  name = "media-configarr-inputs";
                };
              }
              {
                name = "repos";
                emptyDir = { };
              }
            ];
          };
        };
      };
      baseObjects = [
        {
          apiVersion = "v1";
          kind = "ServiceAccount";
          metadata = {
            name = "media-config-seerr";
            namespace = "media";
          };
          automountServiceAccountToken = false;
        }
        {
          apiVersion = "v1";
          kind = "ConfigMap";
          metadata = {
            name = "media-configuration";
            namespace = "media";
          };
          data = configurationData // {
            "roots.mjs" = rootsScript;
            "prowlarr.mjs" = prowlarrScript;
            "seerr.mjs" = seerrScript;
          };
        }
        {
          apiVersion = "v1";
          kind = "ConfigMap";
          metadata = {
            name = "media-configarr-templates";
            namespace = "media";
          };
          data = templateFiles;
        }
        {
          apiVersion = "v1";
          kind = "ConfigMap";
          metadata = {
            name = "media-configarr-inputs";
            namespace = "media";
          };
          data = trashInputs;
        }
      ];
      rootsScript = ''
        import { readFileSync } from 'node:fs';
        const policy = JSON.parse(readFileSync('/configuration/roots.json', 'utf8'));
        const secret = name => {
          const value = readFileSync('/secrets/' + name, 'utf8').replace(/\r?\n$/, "");
          if (!value.trim()) throw new Error('Empty required Secret key: ' + name);
          return value;
        };
        function api(base, headers = {}) {
          return async (path, method = 'GET', body) => {
            let response;
            try {
              response = await fetch(base + path, {
                method,
                headers: { 'Content-Type': 'application/json', ...headers },
                body: body === undefined ? undefined : JSON.stringify(body),
                signal: AbortSignal.timeout(20000),
                redirect: 'error',
              });
            } catch {
              throw new Error(method + ' ' + path + ': dependency unreachable');
            }
            if (!response.ok) throw new Error(method + ' ' + path + ': HTTP ' + response.status);
            const text = await response.text();
            return text ? JSON.parse(text) : null;
          };
        }
        function one(items, predicate, label) {
          const matches = items.filter(predicate);
          if (matches.length > 1) throw new Error('Ambiguous managed ' + label);
          return matches[0];
        }
        for (const [kind, instances] of Object.entries(policy.arr)) {
          for (const desired of Object.values(instances)) {
            const request = api(desired.url + '/api/v3', { 'X-Api-Key': secret(desired.apiSecretKey) });
            const roots = await request('/rootfolder');
            if (!one(roots, root => root.path === desired.root, 'root')) {
              await request('/rootfolder', 'POST', { path: desired.root });
            }
          }
        }
        console.log('media roots: declared roots reconciled');
      '';
      prowlarrScript = builtins.readFile ./prowlarr.mjs;
      seerrScript = builtins.readFile ./seerr.mjs;
    in
    {
      applications.media-configuration = {
        namespace = "media";
        annotations."argocd.argoproj.io/sync-wave" = "3";
        objects = baseObjects ++ [
          (hook "media-config-roots" 0 rootJob)
          (hook "media-configarr" 1 configarrJob)
          (hook "media-config-prowlarr" 1 prowlarrJob)
          (hook "media-config-seerr" 2 seerrJob)
        ];
      };
    };
}
