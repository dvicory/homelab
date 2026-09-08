{ lib, den, ... }:
{
  den.aspects.kubernetes.services.media = {
    settings.configurationSecret = lib.mkOption {
      type = lib.types.str;
      default = "media-runtime";
      description = ''
        Runtime Secret in media containing native Arr API keys, SABnzbd
        credentials and the Jellyfin administrator credentials used only for
        Seerr's supported first-owner login. Values stay in the runtime Secret.
      '';
    };
    includes = [
      den.aspects.kubernetes.services.media.configuration
    ];
  };

  den.aspects.kubernetes.services.media.configuration.compute-resources =
    { cluster, ... }:
    let
      name = cluster.settings.kubernetes.services.media.configurationSecret;
    in
    {
      runtimeSecrets = lib.listToAttrs (
        map
          (key: {
            name = "media--${name}--${key}";
            value = {
              namespace = "media";
              inherit name key;
            };
          })
          [
            "JELLYFIN_OWNER_USERNAME"
            "JELLYFIN_OWNER_PASSWORD"
            "JELLYFIN_OWNER_EMAIL"
          ]
      );
    };
  den.aspects.kubernetes.services.media.configuration.k8s-manifests =
    { cluster, config, ... }:
    let
      policy = import ./_media-policy.nix;
      apps = lib.mapAttrs (
        name: application:
        let
          values = application.helm.releases.${name}.values;
        in
        {
          namespace = application.namespace;
          service = values.fullnameOverride or name;
          port = values.service.main.ports.http.port;
        }
      ) config.applications;
      images = builtins.mapAttrs (_: image: "${image.repository}:${image.tag}@${image.digest}") {
        inherit (policy.images) configarr;
        seerr = config.applications.seerr.helm.releases.seerr.values.controllers.main.containers.main.image;
      };
      retained = {
        "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
      };

      yaml = builtins.toJSON;

      inherit (import ./_media-lib.nix { inherit lib; }) serviceName;

      routePrefix =
        route:
        if route == null || route.pathPrefix == "/" then "" else lib.removeSuffix "/" route.pathPrefix;

      routeFor =
        {
          cluster,
          kind,
          instanceName,
          cfg,
        }:
        let
          routeKey = cfg.routeKey;
          expected = {
            namespace = apps.${serviceName kind instanceName}.namespace;
            service = serviceName kind instanceName;
            port = apps.${serviceName kind instanceName}.port;
          };
        in
        if routeKey == null then
          null
        else
          assert lib.assertMsg (builtins.hasAttr routeKey cluster.routes)
            "Media instance ${kind}/${instanceName} references missing route ${routeKey}.";
          let
            route = builtins.getAttr routeKey cluster.routes;
          in
          assert lib.assertMsg
            (
              route.namespace == expected.namespace
              && route.service == expected.service
              && route.port == expected.port
            )
            "Media route ${routeKey} must target ${expected.namespace}/${expected.service}:${toString expected.port}.";
          route;

      fixedRoute =
        {
          cluster,
          name,
          app,
        }:
        assert lib.assertMsg (builtins.hasAttr name cluster.routes) "Media route ${name} is not declared.";
        let
          route = builtins.getAttr name cluster.routes;
        in
        assert lib.assertMsg (
          route.namespace == app.namespace && route.service == app.service && route.port == app.port
        ) "Media route ${name} must target ${app.namespace}/${app.service}:${toString app.port}.";
        route;

      endpoint =
        {
          route,
          service,
          namespace,
          port,
        }:
        "http://${service}.${namespace}.svc:${toString port}${routePrefix route}";

      external = route: "https://${builtins.head route.hostnames}${routePrefix route}";

      instanceEntries =
        let
          settings = { };
          make = kind: instances: lib.mapAttrsToList (name: cfg: { inherit kind name cfg; }) instances;
        in
        (make "radarr" { }) ++ (make "sonarr" { });

      instancePolicy =
        {
          cluster,
          kind,
          instanceName,
          cfg,
        }:
        let
          route = routeFor {
            inherit
              cluster
              kind
              instanceName
              cfg
              ;
          };
          app = apps.${serviceName kind instanceName};
        in
        {
          url = endpoint {
            inherit route;
            service = serviceName kind instanceName;
            namespace = app.namespace;
            port = app.port;
          };
          externalUrl = if route == null then null else external route;
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

      firstPolicy =
        cluster: kind: instances:
        let
          name = builtins.head (builtins.attrNames instances);
          cfg = builtins.getAttr name instances;
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
          jellyfinRoute = fixedRoute {
            inherit cluster;
            name = "jellyfin";
            app = apps.jellyfin;
          };
          requestsRoute = fixedRoute {
            inherit cluster;
            name = "requests";
            app = apps.seerr;
          };
          sabnzbdRoute = fixedRoute {
            inherit cluster;
            name = "sabnzbd";
            app = apps.sabnzbd;
          };
        in
        {
          roots = builtins.toJSON (rootsPolicy cluster);
          seerr = builtins.toJSON {
            arr = {
              radarr = firstPolicy cluster "radarr" settings.radarr;
              sonarr = firstPolicy cluster "sonarr" settings.sonarr;
            };
            seerr = {
              url = endpoint {
                route = requestsRoute;
                service = apps.seerr.service;
                namespace = apps.seerr.namespace;
                port = apps.seerr.port;
              };
              applicationUrl = external requestsRoute;
            };
            jellyfin = {
              ip = "${apps.jellyfin.service}.${apps.jellyfin.namespace}.svc";
              port = apps.jellyfin.port;
              useSsl = jellyfinRoute.backendTLS;
              urlBase = routePrefix jellyfinRoute;
              externalHostname = external jellyfinRoute;
            };
            # Keep this value visible in the evaluated policy: SAB is configured by
            # its own native INI initializer, not by Seerr or the Arr reconciler.
            sab = {
              host = "${sabnzbdRoute.service}.${sabnzbdRoute.namespace}.svc";
              port = sabnzbdRoute.port;
            };
          };
          inherit (policy) trashRevision;
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
        "radarr-movie.json" = policy.trashFiles.radarrMovie;
        "sonarr-series.json" = policy.trashFiles.sonarrSeries;
        "sonarr-anime.json" = policy.trashFiles.sonarrAnime;
        "conflicts.json" = ''{ "custom_formats": [] }'';
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
        printf '%s\n' '${policy.trashRevision}' > /app/repos/trash-guides/TRASH-GUIDES-REVISION
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
          optionalSecretKeys ? [ ],
        }:
        {
          backoffLimit = 6;
          activeDeadlineSeconds = 900;
          template = {
            metadata.labels."app.kubernetes.io/name" = name;
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
              containers = [
                {
                  name = "configure";
                  inherit image command;
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
                    ]
                    ++ lib.optional (optionalSecretKeys != [ ]) {
                      secret = {
                        name = secretName;
                        optional = true;
                        items = map (key: {
                          inherit key;
                          path = key;
                        }) optionalSecretKeys;
                      };
                    };
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

      cron = name: spec: {
        apiVersion = "batch/v1";
        kind = "CronJob";
        metadata = {
          inherit name;
          namespace = "media";
        };
        spec = {
          schedule = "0 4 * * *";
          suspend = true;
          concurrencyPolicy = "Forbid";
          successfulJobsHistoryLimit = 1;
          failedJobsHistoryLimit = 2;
          jobTemplate.spec = spec;
        };
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
        "seerr.json" = generatedPolicy.seerr;
        "trash-guide-revision" = generatedPolicy.trashRevision;
      };
      templateFiles = templates cluster;
      rootJob = baseJob {
        name = "media-config-roots";
        image = images.seerr;
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
      seerrJob = baseJob {
        name = "media-config-seerr";
        image = images.seerr;
        command = [
          "node"
          "/configuration/seerr.mjs"
        ];
        secretName = secretName;
        secretKeys = arrSecretKeys ++ [
          "JELLYFIN_OWNER_USERNAME"
          "JELLYFIN_OWNER_PASSWORD"
          "JELLYFIN_OWNER_EMAIL"
        ];
        optionalSecretKeys = [ "SEERR_API_KEY" ];
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
          kind = "ConfigMap";
          metadata = {
            name = "media-configuration";
            namespace = "media";
          };
          data = configurationData // {
            "roots.mjs" = rootsScript;
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
      seerrScript = ''
        import { readFileSync, existsSync } from 'node:fs';
        const policy = JSON.parse(readFileSync('/configuration/seerr.json', 'utf8'));
        const secret = name => {
          const value = readFileSync('/secrets/' + name, 'utf8').replace(/\r?\n$/, "");
          if (!value.trim()) throw new Error('Empty required Secret key: ' + name);
          return value;
        };
        function api(base, headers = {}) {
          const cookies = new Map();
          return async (path, method = 'GET', body) => {
            let response;
            try {
              response = await fetch(base + path, {
                method,
                headers: { 'Content-Type': 'application/json', ...headers,
                  ...(cookies.size ? { Cookie: [...cookies].map(([k, v]) => k + '=' + v).join('; ') } : {}),
                  ...(cookies.has('XSRF-TOKEN') ? { 'X-XSRF-TOKEN': decodeURIComponent(cookies.get('XSRF-TOKEN')) } : {}),
                },
                body: body === undefined ? undefined : JSON.stringify(body),
                signal: AbortSignal.timeout(20000),
                redirect: 'error',
              });
            } catch {
              throw new Error(method + ' ' + path + ': dependency unreachable');
            }
            if (!response.ok) throw new Error(method + ' ' + path + ': HTTP ' + response.status);
            for (const cookie of response.headers.getSetCookie()) {
              const pair = cookie.split(';')[0], index = pair.indexOf('=');
              cookies.set(pair.slice(0, index), pair.slice(index + 1));
            }
            const text = await response.text();
            try { return text ? JSON.parse(text) : null; }
            catch { throw new Error(method + ' ' + path + ': invalid JSON response'); }
          };
        }
        function one(items, predicate, label) {
          const matches = items.filter(predicate);
          if (matches.length > 1) throw new Error('Ambiguous managed ' + label);
          return matches[0];
        }
        async function configure() {
          const base = policy.seerr.url + '/api/v1';
          const headers = { Origin: policy.seerr.url };
          const request = api(base, headers);
          const publicSettings = await request('/settings/public');
          if (existsSync('/secrets/SEERR_API_KEY')) {
            headers['X-Api-Key'] = secret('SEERR_API_KEY');
          } else {
            const login = {
              username: secret('JELLYFIN_OWNER_USERNAME'),
              password: secret('JELLYFIN_OWNER_PASSWORD'),
              email: secret('JELLYFIN_OWNER_EMAIL'),
              serverType: 2,
            };
            if (publicSettings.mediaServerType === 4) Object.assign(login, {
              hostname: policy.jellyfin.ip,
              port: policy.jellyfin.port,
              useSsl: policy.jellyfin.useSsl,
              urlBase: policy.jellyfin.urlBase,
            });
            const session = await request('/auth/jellyfin', 'POST', login);
            if (session.id !== 1) throw new Error('Runtime Jellyfin account is not the Seerr owner (id 1)');
            headers['X-Api-Key'] = (await request('/settings/main')).apiKey;
          }
          const owner = await request('/auth/me');
          if (owner.id !== 1) throw new Error('Configuration requires Seerr owner');
          await request('/settings/jellyfin', 'POST', policy.jellyfin);
          await request('/settings/main', 'POST', { applicationUrl: policy.seerr.applicationUrl });
          for (const [name, desired] of Object.entries(policy.arr)) {
            const profiles = await api(desired.url + '/api/v3', { 'X-Api-Key': secret(desired.apiSecretKey) })('/qualityprofile');
            const profile = one(profiles, item => item.name === desired.profile, 'Seerr quality profile');
            if (!profile) throw new Error('Run Configarr before Seerr');
            const path = '/settings/' + name;
            const connectionName = name === 'radarr' ? 'Radarr' : 'Sonarr';
            const existing = one(await request(path), item => item.name === connectionName, 'Seerr connection');
            const url = new URL(desired.url);
            const server = {
              tags: [], overrideRule: [], tagRequests: false,
              ...(existing || {}),
              name: connectionName,
              hostname: url.hostname,
              port: Number(url.port),
              useSsl: false,
              baseUrl: url.pathname === '/' ? "" : url.pathname,
              apiKey: secret(desired.apiSecretKey),
              activeProfileId: profile.id,
              activeProfileName: desired.profile,
              activeDirectory: desired.root,
              externalUrl: desired.externalUrl,
              isDefault: true,
              is4k: false,
              syncEnabled: true,
              preventSearch: false,
              ...(name === 'radarr' ? { minimumAvailability: 'released' } : {
                seriesType: 'standard',
                animeSeriesType: 'anime',
                activeAnimeProfileId: profile.id,
                activeAnimeProfileName: desired.profile,
                activeAnimeDirectory: desired.root,
                enableSeasonFolders: true,
                monitorNewItems: 'all',
              }),
            };
            delete server.id;
            await request(path + '/test', 'POST', server);
            await request(path + (existing ? '/' + existing.id : ""), existing ? 'PUT' : 'POST', server);
          }
          await request('/settings/initialize', 'POST');
        }
        try {
          await configure();
          console.log('seerr: declared Jellyfin and Arr servers reconciled');
        } catch (error) {
          console.error(error.message);
          process.exitCode = 1;
        }
      '';
    in
    {
      applications.media-configuration = {
        objects = baseObjects ++ [
          (hook "media-config-roots" 0 rootJob)
          (cron "media-config-roots" rootJob)
          (hook "media-configarr" 1 configarrJob)
          (cron "media-configarr" configarrJob)
          (hook "media-config-seerr" 2 seerrJob)
          (cron "media-config-seerr" seerrJob)
        ];
      };
    };
}
