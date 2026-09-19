{ lib, ... }:
{
  den.aspects.kubernetes.services.immich = {
    compute-resources = {
      retainedPaths = {
        immich-library = {
          uid = 1000;
          gid = 1000;
          mode = "0750";
        };
        immich-postgres = {
          uid = 999;
          gid = 999;
          mode = "0700";
        };
      };
      runtimeSecrets."immich--immich-runtime--DB_PASSWORD" = {
        namespace = "immich";
        name = "immich-runtime";
        key = "DB_PASSWORD";
      };
    };
    settings.oidcConfigurationSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional runtime Secret containing immich-config.yaml. The operator
        owns the complete config (including OAuth clientSecret), must keep
        passwordLogin.enabled=true and oauth.autoLaunch=false, and must retain
        a local recovery administrator. Stage this secret before enabling it.
      '';
    };

    k8s-manifests =
      {
        cluster,
        compute,
        charts,
        pkgs,
        lib,
        ...
      }:
      let
        chartSource = lib.helm.downloadHelmChart {
          repo = "oci://ghcr.io/immich-app/immich-charts";
          chart = "immich";
          version = "0.13.1";
          chartHash = "sha256-Ekk7MBUJYc+IOMdUzE2H0LPPrKoLbcwEilZIU/YO/kg=";
        };
        # Embed the already pinned common schema: Helm validation must not
        # fetch GitHub from inside the offline rendering sandbox.
        chart = pkgs.runCommand "immich-chart-offline-schema" { nativeBuildInputs = [ pkgs.jq ]; } ''
          cp -r ${chartSource} "$out"
          chmod u+w "$out" "$out/values.schema.json"
          jq --slurpfile common ${chartSource}/charts/common/values.schema.json \
            '.["$defs"].common = $common[0]' ${chartSource}/values.schema.json \
            > "$out/values.schema.json"
        '';
        namespace = "immich";
        route = cluster.routes.immich;
        configurationSecret = cluster.settings.kubernetes.services.immich.oidcConfigurationSecret;
        retained = {
          "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
        };
        podOptions = {
          nodeSelector."kubernetes.io/hostname" = compute.instance;
          automountServiceAccountToken = false;
          securityContext = {
            runAsUser = compute.retainedPaths.immich-library.uid;
            runAsGroup = compute.retainedPaths.immich-library.gid;
            runAsNonRoot = true;
          };
        };
        containerSecurity = {
          allowPrivilegeEscalation = false;
          capabilities.drop = [ "ALL" ];
        };
        dbPassword.valueFrom.secretKeyRef = {
          name = "immich-runtime";
          key = "DB_PASSWORD";
        };
        storage = name: size: {
          persistentVolumes."immich-${name}" = {
            metadata.annotations = retained;
            spec = {
              capacity.storage = size;
              volumeMode = "Filesystem";
              accessModes = [ "ReadWriteOnce" ];
              persistentVolumeReclaimPolicy = "Retain";
              storageClassName = "";
              local.path = compute.retainedPaths."immich-${name}".guestPath;
              claimRef = {
                inherit namespace;
                name = "immich-${name}";
              };
              nodeAffinity.required.nodeSelectorTerms = [
                {
                  matchExpressions = [
                    {
                      key = "kubernetes.io/hostname";
                      operator = "In";
                      values = [ compute.instance ];
                    }
                  ];
                }
              ];
            };
          };
          persistentVolumeClaims."immich-${name}" = {
            metadata.annotations = retained;
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              storageClassName = "";
              volumeName = "immich-${name}";
              resources.requests.storage = size;
            };
          };
        };
        configuration = lib.optionalAttrs (configurationSecret == null) {
          server.externalDomain = "https://${builtins.head route.hostnames}";
          passwordLogin.enabled = true;
          oauth = {
            enabled = false;
            autoLaunch = false;
          };
        };
      in
      assert lib.assertMsg (
        route.pathPrefix == "/"
      ) "Immich only supports a hostname root; cluster.routes.immich.pathPrefix must be /.";
      assert lib.assertMsg (
        route.namespace == namespace
        && route.service == "immich-server"
        && route.port == 2283
        && !route.backendTLS
      ) "Immich route must target its declared HTTP Service immich/immich-server:2283";
      {
        applications.immich-storage = {
          inherit namespace;
          objects = [
            {
              apiVersion = "v1";
              kind = "Namespace";
              metadata = {
                name = namespace;
                annotations = retained;
              };
            }
          ];
          resources = lib.mkMerge [
            (storage "library" "1Ti")
            (storage "postgres" "32Gi")
          ];
        };

        applications.immich = {
          inherit namespace;
          helm.releases.immich = {
            # nixhelm's catalog still exposes 0.12.0 from the retired HTTP repo;
            # this is the official 0.13.1 OCI chart and its common 5.0.1 library.
            chart = chart;
            values = {
              defaultPodOptions = podOptions;
              controllers.main.containers.main.image.tag = "v3.1.0";
              immich = {
                persistence.library.existingClaim = "immich-library";
              }
              // lib.optionalAttrs (configurationSecret == null) { inherit configuration; }
              // lib.optionalAttrs (configurationSecret != null) {
                configurationKind = "Secret";
                existingConfiguration = configurationSecret;
              };
              server = {
                controllers.main = {
                  strategy = "Recreate";
                  replicas = 1;
                  containers.main = {
                    image.digest = "sha256:b434cb9287eea1471c9974845914d4dd328c9c2d652e446ed4930f99944f0ceb";
                    securityContext = containerSecurity;
                    env = {
                      DB_HOSTNAME = "immich-postgres";
                      DB_PORT = "5432";
                      DB_USERNAME = "immich";
                      DB_DATABASE_NAME = "immich";
                      DB_PASSWORD = dbPassword;
                      REDIS_HOSTNAME = "immich-valkey";
                      REDIS_PORT = "6379";
                      IMMICH_MACHINE_LEARNING_URL = "http://immich-machine-learning:3003";
                      HOME = "/tmp";
                    };
                    resources = {
                      requests = {
                        cpu = "500m";
                        memory = "2Gi";
                      };
                      limits = {
                        cpu = "4";
                        memory = "4Gi";
                      };
                    };
                  };
                };
              };
              machine-learning = {
                controllers.main = {
                  replicas = 1;
                  containers.main = {
                    image = {
                      tag = "v3.1.0";
                      digest = "sha256:5a0839dc5303cd7215bcd2180a26aed3af41675aefb3e75e5157e9f10ad16e6e";
                    };
                    securityContext = containerSecurity;
                    env.HOME = "/cache";
                    resources = {
                      requests = {
                        cpu = "250m";
                        memory = "1Gi";
                      };
                      limits = {
                        cpu = "2";
                        memory = "3Gi";
                      };
                    };
                  };
                };
                persistence.cache = {
                  type = "emptyDir";
                  sizeLimit = "10Gi";
                  globalMounts = [ { path = "/cache"; } ];
                };
              };
              # Current chart dependency; queue/model state is disposable.
              valkey = {
                enabled = true;
                controllers.main.containers.main = {
                  image = {
                    repository = "docker.io/valkey/valkey";
                    tag = "9";
                    digest = "sha256:8e8d64b405ce18f41b8e5ee20aa4687a8ed0022d1298f2ce31cdcf3a76e09411";
                  };
                  securityContext = containerSecurity;
                  args = [
                    "--save"
                    ""
                    "--appendonly"
                    "no"
                    "--maxmemory"
                    "384mb"
                    "--maxmemory-policy"
                    "noeviction"
                  ];
                  resources = {
                    requests = {
                      cpu = "100m";
                      memory = "128Mi";
                    };
                    limits = {
                      cpu = "1";
                      memory = "512Mi";
                    };
                  };
                };
                persistence.data = {
                  type = "emptyDir";
                  sizeLimit = "1Gi";
                };
              };
            };
          };
        };

        applications.immich-postgres = {
          inherit namespace;
          helm.releases.immich-postgres = {
            chart = charts.bjw-s-labs.app-template;
            values = {
              fullnameOverride = "immich-postgres";
              defaultPodOptions = podOptions // {
                securityContext = podOptions.securityContext // {
                  runAsUser = compute.retainedPaths.immich-postgres.uid;
                  runAsGroup = compute.retainedPaths.immich-postgres.gid;
                };
              };
              controllers.main = {
                type = "deployment";
                strategy = "Recreate";
                replicas = 1;
                containers.main = {
                  # Exact PostgreSQL image from the v3.1.0 release compose.
                  image = {
                    repository = "ghcr.io/immich-app/postgres";
                    tag = "14-vectorchord0.4.3-pgvectors0.2.0";
                    digest = "sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23";
                  };
                  securityContext = containerSecurity;
                  env = {
                    POSTGRES_USER = "immich";
                    POSTGRES_DB = "immich";
                    POSTGRES_PASSWORD = dbPassword;
                    POSTGRES_INITDB_ARGS = "--data-checksums";
                    PGDATA = "/var/lib/postgresql/data/pgdata";
                  };
                  probes = builtins.listToAttrs (
                    map
                      (name: {
                        inherit name;
                        value = {
                          enabled = true;
                          custom = true;
                          spec = {
                            exec.command = [
                              "pg_isready"
                              "-U"
                              "immich"
                              "-d"
                              "immich"
                            ];
                            periodSeconds = 10;
                            timeoutSeconds = 5;
                            failureThreshold = if name == "startup" then 60 else 3;
                          };
                        };
                      })
                      [
                        "startup"
                        "readiness"
                        "liveness"
                      ]
                  );
                  resources = {
                    requests = {
                      cpu = "250m";
                      memory = "512Mi";
                    };
                    limits = {
                      cpu = "2";
                      memory = "2Gi";
                    };
                  };
                };
              };
              service.main = {
                controller = "main";
                forceRename = "immich-postgres";
                ports.postgres.port = 5432;
              };
              persistence = {
                data = {
                  existingClaim = "immich-postgres";
                  globalMounts = [ { path = "/var/lib/postgresql/data"; } ];
                };
                shm = {
                  type = "emptyDir";
                  medium = "Memory";
                  sizeLimit = "128Mi";
                  globalMounts = [ { path = "/dev/shm"; } ];
                };
              };
            };
          };
        };
      };
  };
}
