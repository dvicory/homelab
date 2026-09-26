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
    { cluster, computeResources, ... }:
    let
      settings = cluster.settings.kubernetes.services.media;
      policySource = builtins.fromJSON (
        builtins.readFile (inputs.self + "/assets/media-policy/source.json")
      );
      pinnedInput = name: builtins.readFile (inputs.self + "/assets/media-policy/${name}");
      profileData = kind: bundle: builtins.fromJSON (pinnedInput "${kind}-${bundle}.json");
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
          tag = "1.32.0";
          digest = "sha256:8a94c8355f86619ac4c52298144f15859f9c66311515f96c4688435fa020039e";
        };
        node = {
          repository = "docker.io/library/node";
          tag = "22.14.0-bookworm-slim";
          digest = "sha256:1c18d9ab3af4585870b92e4dbc5cac5a0dc77dd13df1a5905cea89fc720eb05b";
        };
      };
      trashRevision = policySource.revision;
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
          profile = (profileData kind cfg.bundle).name;
          bundle = cfg.bundle;
          apiSecretKey = cfg.apiSecretKey;
        };

      profileTemplate =
        kind: bundle:
        let
          profile = profileData kind bundle;
          quality =
            item:
            "      - name: ${yaml item.name}\n"
            + "        enabled: ${if item.allowed then "true" else "false"}\n"
            + lib.optionalString (item ? items) "        qualities: ${yaml item.items}\n";
        in
        ''
          # ${policySource.repository}/blob/${policySource.revision}/${
            policySource.files."${kind}-${bundle}.json".upstream
          }
          quality_profiles:
            - name: ${yaml profile.name}
              upgrade:
                allowed: ${if profile.upgradeAllowed then "true" else "false"}
                until_quality: ${yaml profile.cutoff}
                until_score: ${toString profile.cutoffFormatScore}
                min_format_score: ${toString profile.minUpgradeFormatScore}
              min_format_score: ${toString profile.minFormatScore}
          ${lib.optionalString (profile ? language) "    language: ${yaml profile.language}\n"}
              qualities:
          ${lib.concatMapStrings quality profile.items}
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
              custom_formats:
                - trash_ids: ${yaml (builtins.attrValues (profileData kind cfg.bundle).formatItems)}
                  assign_scores_to:
                    - name: ${yaml desired.profile}
                      use_default_score: true
              root_folders:
                - ${yaml cfg.root}
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

      seerrPolicy =
        cluster: kind: instances:
        let
          selected = role: lib.filter (name: instances.${name}.role == role) (builtins.attrNames instances);
          standard = selected "standard";
          fourK = selected "4k";
          fact =
            name:
            (instancePolicy {
              inherit cluster kind;
              cfg = instances.${name};
              instanceName = name;
            })
            // {
              inherit name;
            };
        in
        assert lib.assertMsg (
          builtins.length standard == 1
        ) "Exactly one ${kind} instance must have role = standard for Seerr.";
        assert lib.assertMsg (
          builtins.length fourK <= 1
        ) "At most one ${kind} instance may have role = 4k for Seerr.";
        {
          standard = fact (builtins.head standard);
        }
        // lib.optionalAttrs (fourK != [ ]) { "4k" = fact (builtins.head fourK); };

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
          applications =
            lib.concatMap
              (
                kind:
                lib.mapAttrsToList (instanceName: cfg: {
                  name = "homelab-${services.${kind}.${instanceName}.service}";
                  implementation = if kind == "radarr" then "Radarr" else "Sonarr";
                  baseUrl = endpoint services.${kind}.${instanceName};
                  apiSecretKey = cfg.apiSecretKey;
                  syncLevel = "fullSync";
                  prowlarrUrl = endpoint apps.prowlarr;
                }) settings.${kind}
              )
              [
                "radarr"
                "sonarr"
              ];
          prowlarrApps = lib.concatMapStringsSep "\n" (
            application:
            "        - name: ${yaml application.name}\n"
            + "          type: ${yaml application.implementation}\n"
            + "          sync_level: ${yaml application.syncLevel}\n"
            + "          fields:\n"
            + "            prowlarrUrl: ${yaml application.prowlarrUrl}\n"
            + "            baseUrl: ${yaml application.baseUrl}\n"
            + "            apiKey: !env ${application.apiSecretKey}"
          ) applications;
        in
        ''
          # Configarr v1.32.0: Git URLs refer to locally seeded, detached policy inputs.
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
          prowlarr:
            main:
              base_url: ${yaml (endpoint apps.prowlarr)}
              api_key: !env ${prowlarrSecretKey}
              applications:
                data:
          ${prowlarrApps}
                delete_unmanaged:
                  enabled: false
        '';

      policyConfig =
        cluster:
        let
          settings = cluster.settings.kubernetes.services.media;
          jellyfinRoute = cluster.routes.jellyfin;
        in
        {
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
              namespace = apps.jellyfin.namespace;
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
                value = profileTemplate kind cfg.bundle;
              }) instances
            );
        in
        (make "radarr" settings.radarr) // (make "sonarr" settings.sonarr);

      cfFiles = lib.filterAttrs (name: _: lib.hasInfix "-cf-" name) policySource.files;
      trashInputs = {
        "radarr-movie.json" = builtins.readFile (inputs.self + "/assets/media-policy/radarr-movie.json");
        "sonarr-series.json" = builtins.readFile (inputs.self + "/assets/media-policy/sonarr-series.json");
        "sonarr-anime.json" = builtins.readFile (inputs.self + "/assets/media-policy/sonarr-anime.json");
        "conflicts.json" = builtins.readFile (inputs.self + "/assets/media-policy/conflicts.json");
      }
      // lib.mapAttrs (name: _: pinnedInput name) cfFiles;

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
        ${lib.concatMapStringsSep "\n" (
          name: "cp /seed/${name} /app/repos/trash-guides/${cfFiles.${name}.upstream}"
        ) (builtins.attrNames cfFiles)}
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
          nodeSelector ? null,
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
            }
            // lib.optionalAttrs (nodeSelector != null) { inherit nodeSelector; };
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
      periodic = name: minute: jobSpec: {
        apiVersion = "batch/v1";
        kind = "CronJob";
        metadata = {
          inherit name;
          namespace = "media";
        };
        spec = {
          schedule = "${toString minute} */6 * * *";
          suspend = false;
          concurrencyPolicy = "Forbid";
          startingDeadlineSeconds = 900;
          successfulJobsHistoryLimit = 1;
          failedJobsHistoryLimit = 1;
          jobTemplate.spec = jobSpec;
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
        "seerr.json" = generatedPolicy.seerr;
        "trash-guide-revision" = generatedPolicy.trashRevision;
      };
      templateFiles = templates cluster;
      seerrJob = baseJob {
        name = "media-config-seerr";
        image = images.node;
        command = [
          "node"
          "/configuration/seerr.mjs"
        ];
        secretName = secretName;
        secretKeys = arrSecretKeys ++ [ "SEERR_API_KEY" ];
        serviceAccountName = "media-config-seerr";
        nodeSelector."kubernetes.io/hostname" = computeResources.instance;
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
          {
            name = "seerr-state";
            mountPath = "/seerr-state";
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
            name = "seerr-state";
            persistentVolumeClaim.claimName = "media-seerr";
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
      readinessTargets = builtins.toJSON (
        lib.concatMap
          (
            kind:
            lib.mapAttrsToList (name: cfg: {
              url = "${endpoint services.${kind}.${name}}/api/v3/system/status";
              key = cfg.apiSecretKey;
            }) settings.${kind}
          )
          [
            "radarr"
            "sonarr"
          ]
        ++ [
          {
            url = "${endpoint apps.prowlarr}/api/v1/system/status";
            key = prowlarrSecretKey;
          }
        ]
      );
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
                name = "wait-for-apis";
                image = images.node;
                command = [
                  "node"
                  "-e"
                  ''
                    const targets = JSON.parse(process.env.READY_TARGETS);
                    const deadline = Date.now() + 600000;
                    async function ready(target) {
                      while (true) {
                        try {
                          const response = await fetch(target.url, {
                            headers: { 'X-Api-Key': process.env[target.key] },
                            signal: AbortSignal.timeout(10000),
                          });
                          if (response.ok) return;
                        } catch {}
                        if (Date.now() + 5000 >= deadline) throw new Error('Media API readiness timed out: ' + target.url);
                        await new Promise(resolve => setTimeout(resolve, 5000));
                      }
                    }
                    Promise.all(targets.map(ready)).catch(error => { console.error(error); process.exitCode = 1; });
                  ''
                ];
                env = [
                  {
                    name = "READY_TARGETS";
                    value = readinessTargets;
                  }
                ]
                ++ map (secretEnv secretName) (arrSecretKeys ++ [ prowlarrSecretKey ]);
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
              }
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
                # Configarr 1.32 can report failed API writes while exiting zero.
                command = [
                  "/bin/sh"
                  "-ec"
                  ''
                    output="$(dumb-init node index.js 2>&1)" || {
                      printf '%s\n' "$output"
                      exit 1
                    }
                    printf '%s\n' "$output"
                    case "$output" in
                      *"ERROR "*|*"change(s) failed"*) exit 1 ;;
                    esac
                  ''
                ];
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
                  {
                    name = "CONFIGARR_ENFORCE_CONFIG_VALIDATION";
                    value = "true";
                  }
                  {
                    name = "CONFIGARR_ENFORCE_EXTERNAL_VALIDATION";
                    value = "true";
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
                    prowlarrSecretKey
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
      seerrScript = builtins.readFile ./seerr.mjs;
    in
    {
      applications.media-configuration = {
        namespace = "media";
        annotations."argocd.argoproj.io/sync-wave" = "3";
        objects = baseObjects ++ [
          (hook "media-configarr" 1 configarrJob)
          (hook "media-config-seerr" 2 seerrJob)
          (periodic "media-configarr" 7 configarrJob)
          (periodic "media-config-seerr" 37 seerrJob)
        ];
      };
    };
}
