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

  # Integration-owned coordination for Configarr and Seerr, separate from
  # application state. The retained-directories owner prepares this identity.
  den.aspects.kubernetes.services.media.configuration.compute-resources = _: {
    retainedPaths.media-seerr-configuration = {
      uid = 1000;
      gid = 1000;
      mode = "0700";
    };
  };

  den.aspects.kubernetes.services.media.configuration.k8s-manifests =
    { cluster, computeResources, ... }:
    let
      settings = cluster.settings.kubernetes.services.media;
      initialSeerr = cluster.settings.kubernetes.services.seerr.phase == "initial";
      coordination = computeResources.retainedPaths.media-seerr-configuration;
      retain = {
        "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
      };
      policySource = builtins.fromJSON (
        builtins.readFile (inputs.self + "/assets/media-policy/source.json")
      );
      localPolicy = name: builtins.fromJSON (
        builtins.readFile (inputs.self + "/assets/media-policy/${name}.json")
      );
      requiredFormats = localPolicy "required-formats";
      preferredProfile = localPolicy "hd-preferred";
      profileData = kind: key: policySource.profiles.${kind}.${key};
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
      arrFacts = kind: lib.mapAttrs (_: cfg: factFor cfg.integration) settings.${kind};
      services = {
        prowlarr = factFor (
          cluster.settings.kubernetes.services.prowlarr.integration // { routeKey = "prowlarr"; }
        );
        sabnzbd = factFor (
          cluster.settings.kubernetes.services.sabnzbd.integration // { routeKey = "sabnzbd"; }
        );
        seerr = factFor (
          cluster.settings.kubernetes.services.seerr.integration // { routeKey = "requests"; }
        );
        radarr = arrFacts "radarr";
        sonarr = arrFacts "sonarr";
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
        assert lib.assertMsg (cfg.role != "4k")
          "Homelab-managed HD quality profiles cannot serve Seerr's 4k role (${kind}/${instanceName}).";
        {
          url = endpoint fact;
          externalUrl = fact.externalUrl;
          root = cfg.root;
          category = cfg.category;
          profile = (profileData kind cfg.defaultQualityProfile).name;
          inherit (cfg) qualityProfiles defaultQualityProfile;
          apiSecretKey = fact.apiSecretKey;
        };

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
                kind
                instanceName
                cfg
                ;
            };
            categoryField = if kind == "radarr" then "movie_category" else "tv_category";
            customFormats = lib.concatMap (
              key:
              [
                {
                  trash_ids = requiredFormats.${kind}.default;
                  assign_scores_to = [
                    {
                      name = (profileData kind key).name;
                      use_default_score = true;
                    }
                  ];
                }
              ]
              ++ lib.optional (requiredFormats.${kind}.zero != [ ]) {
                # The guide explicitly scores these at zero, but their CF JSON
                # omits a default. An undefined score would preserve drift.
                trash_ids = requiredFormats.${kind}.zero;
                assign_scores_to = [
                  {
                    name = (profileData kind key).name;
                    score = 0;
                  }
                ];
              }
            ) cfg.qualityProfiles;
            includes = map (key: {
              template = (profileData kind key).id;
              source = "TRASH";
              trash_cfgroup_include_optional = false;
              # Native required groups otherwise add audio/UHD/extra services.
              trash_cfgroup_exclude_cfs = map (id: { inherit id; }) requiredFormats.${kind}.excludeNativeGroups;
            }) cfg.qualityProfiles;
            profiles = map (key: {
              name = (profileData kind key).name;
              # Native include merging otherwise resets unrelated UI scores.
              reset_unmatched_scores.enabled = false;
              upgrade.min_format_score = 1;
            } // lib.optionalAttrs (key == "hd-preferred") preferredProfile) cfg.qualityProfiles;
            renames = lib.concatMap (key:
              let profile = profileData kind key;
              in lib.optional (profile.name != profile.upstreamName) {
                from = profile.upstreamName;
                to = profile.name;
              }
            ) cfg.qualityProfiles;
          in
          ''
            ${yaml instanceName}:
              base_url: ${yaml desired.url}
              api_key: !env ${cfg.apiSecretKey}
              quality_definition:
                type: ${if kind == "radarr" then "movie" else "series"}
              include: ${yaml includes}
              renameQualityProfiles: ${yaml renames}
              quality_profiles: ${yaml profiles}
              custom_formats: ${yaml customFormats}
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
                      api_key: !env ${apps.sabnzbd.apiSecretKey}
                      # SABnzbd has no web login; clear any stored one.
                      username: ""
                      password: ""
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
              inherit kind;
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
          trashGuideUrl: ${yaml policySource.repository}
          trashRevision: ${yaml trashRevision}
          recyclarrConfigUrl: ${yaml policySource.templateRepository}
          recyclarrRevision: ${yaml policySource.templateRevision}
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
              inherit (apps.seerr) apiSecretKey;
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
              # Only the video libraries intended for requests.
              libraries = map (library: { inherit (library) name collectionType; }) (
                lib.filter (library: library.requestable or false) apps.jellyfin.libraries
              );
              secret = apps.jellyfin.adminSecret;
            };
            # Keep this value visible in the evaluated policy: SAB is configured by
            # its own native INI initializer, not by Seerr or the Arr reconciler.
            sab = {
              host = "${apps.sabnzbd.service}.${apps.sabnzbd.namespace}.svc";
              port = apps.sabnzbd.port;
            };
          };
        };

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
                    # No fsGroup on this pod: it mounts the retained media-seerr
                    # PVC, and fsGroup would chown that volume recursively.
                    defaultMode = 292;
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
      };
      seerrJob = bootstrap: baseJob {
        name = "media-config-seerr";
        image = images.node;
        command = [
          # Both entry points lock the same local inode. --no-fork carries the
          # kernel lock through Node's lifetime, including failure/SIGTERM;
          # never unlink the lock file or use Seerr's private state for it.
          "/usr/bin/flock"
          "--no-fork"
          "--wait"
          "900"
          "/coordination/seerr.lock"
          "node"
          "/configuration/seerr.mjs"
        ];
        secretName = secretName;
        secretKeys = arrSecretKeys ++ [ apps.seerr.apiSecretKey ];
        serviceAccountName = if bootstrap then "media-config-seerr-bootstrap" else "media-config-seerr";
        nodeSelector."kubernetes.io/hostname" = computeResources.instance;
        env = lib.optionals bootstrap [
          {
            name = "SEERR_INITIAL_OWNER";
            value = "true";
          }
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
            name = "coordination";
            mountPath = "/coordination";
          }
        ] ++ lib.optionals bootstrap [
          {
            name = "seerr-state";
            mountPath = "/seerr-state";
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
            name = "coordination";
            persistentVolumeClaim.claimName = "media-seerr-configuration";
          }
        ] ++ lib.optionals bootstrap [
          {
            name = "seerr-state";
            persistentVolumeClaim.claimName = "media-seerr";
          }
          {
            name = "kubernetes-api";
            projected = {
              defaultMode = 292;
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
                    exec 9>/coordination/configarr.lock
                    flock -x 9
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
                    value = "/coordination/configarr-repos/${trashRevision}-${policySource.templateRevision}";
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
                  arrSecretKeys
                  ++ [
                    apps.sabnzbd.apiSecretKey
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
                    name = "coordination";
                    mountPath = "/coordination";
                  }
                ];
              }
            ];
            volumes = [
              {
                name = "coordination";
                persistentVolumeClaim.claimName = "media-seerr-configuration";
              }
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
      ] ++ lib.optionals initialSeerr [
        {
          apiVersion = "v1";
          kind = "ServiceAccount";
          metadata = {
            name = "media-config-seerr-bootstrap";
            namespace = "media";
          };
          automountServiceAccountToken = false;
        }
      ] ++ [
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
      ];
      seerrScript = builtins.readFile ./seerr.mjs;
    in
    assert lib.assertMsg (
      coordination.uid == 1000 && coordination.gid == 1000
      && coordination.mode == "0700" && !coordination.readOnly
    ) "Media configuration coordination must be private writable integration-owned storage.";
    {
      applications.media-seerr-configuration-storage = {
        namespace = "media";
        annotations."argocd.argoproj.io/sync-wave" = "0";
        retained = true;
        objects = [
          {
            apiVersion = "v1";
            kind = "PersistentVolume";
            metadata = {
              name = "media-seerr-configuration";
              annotations = retain;
            };
            spec = {
              capacity.storage = "1Mi";
              accessModes = [ "ReadWriteOnce" ];
              persistentVolumeReclaimPolicy = "Retain";
              storageClassName = "";
              local.path = coordination.guestPath;
              claimRef = {
                namespace = "media";
                name = "media-seerr-configuration";
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
              name = "media-seerr-configuration";
              namespace = "media";
              annotations = retain;
            };
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              storageClassName = "";
              volumeName = "media-seerr-configuration";
              resources.requests.storage = "1Mi";
            };
          }
        ];
      };
      applications.media-configuration = {
        namespace = "media";
        annotations."argocd.argoproj.io/sync-wave" = "3";
        objects = baseObjects ++ [
          (hook "media-configarr" 1 configarrJob)
          (hook "media-config-seerr" 2 (seerrJob initialSeerr))
          (periodic "media-configarr" 7 configarrJob)
          (periodic "media-config-seerr" 37 (seerrJob false))
        ];
      };
    };
}
