{
  config,
  inputs,
  lib,
  ...
}:
let
  namespace = "jellyfin";
  integration = {
    inherit namespace;
    service = "jellyfin";
    port = 8096;
    host = "jellyfin.jellyfin.svc.cluster.local";
    administrator = "daniel";
    adminSecret = {
      name = "jellyfin-admin";
      key = "password";
    };
    # Jellarr creates one library per media class of the read-only /media
    # projection. requestable marks the video libraries Seerr offers for
    # requests; a later library (music, audiobooks) need not be.
    libraries = [
      {
        name = "Movies";
        collectionType = "movies";
        directory = "movies";
        requestable = true;
      }
      {
        name = "Shows";
        collectionType = "tvshows";
        directory = "tv";
        requestable = true;
      }
    ];
  };
  retain = {
    "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
  };
  identity = {
    uid = 751;
    gid = 751;
  };
  mediaGid = (config.den.groups or { }).media.gid;
  gpuRenderGid = (config.den.groups or { }).gpu-render.gid;
  # Jellarr writes only these keys; throttling, segment deletion, tone mapping
  # and every other encoding setting stay application-owned. Its codec-list
  # diff never removes an entry, so software mode leaves the list alone;
  # nothing reads it while the acceleration type is `none`.
  hardwareEncoding = renderNode: {
    intel = {
      enableHardwareEncoding = true;
      hardwareAccelerationType = "qsv";
      qsvDevice = renderNode;
      vaapiDevice = renderNode;
      hardwareDecodingCodecs = [
        "h264"
        "hevc"
        "mpeg2video"
        "vc1"
        "vp9"
        "av1"
      ];
      enableDecodingColorDepth10Hevc = true;
      enableDecodingColorDepth10Vp9 = true;
      enableDecodingColorDepth10HevcRext = true;
      enableDecodingColorDepth12HevcRext = true;
      allowHevcEncoding = false;
      allowAv1Encoding = false;
    };
  };
  softwareEncoding = {
    enableHardwareEncoding = false;
    hardwareAccelerationType = "none";
  };
in
{
  den.aspects.kubernetes.services.jellyfin.settings.integration = lib.mkOption {
    type = lib.types.attrs;
    readOnly = true;
    default = integration;
    description = "Read-only Jellyfin endpoint, administrator Secret reference and configured libraries for consumers.";
  };

  # The one literal lives in `integration`; keep the provisioner-facing setting
  # defaulted to it.
  den.aspects.kubernetes.services.jellyfin.settings.administrator = lib.mkOption {
    # Jellyfin 12.1 UserManager.ThrowIfInvalidUsername accepts
    # ^(?!\s)[\w\ \-'._@+]+(?<!\s)$ except "." and "..". The patched
    # provisioner checks only that the name is not blank, then fails partway
    # through provisioning on any other name. Accept the ASCII subset of that
    # rule here so a bad name fails evaluation instead.
    type = lib.types.addCheck (lib.types.strMatching "[A-Za-z0-9_.'@+-]([A-Za-z0-9_ .'@+-]*[A-Za-z0-9_.'@+-])?") (
      name: name != "." && name != ".."
    );
    default = integration.administrator;
    description = ''
      Initial declarative Jellyfin administrator name: ASCII letters, digits,
      spaces (not leading or trailing), and `_ . ' @ + -`, other than `.` or `..`.
    '';
  };

  den.aspects.kubernetes.services.jellyfin.settings.transcoding = lib.mkOption {
    type = lib.types.enum [
      "hardware"
      "software"
    ];
    default = "hardware";
    description = ''
      Declared transcoding mode. `hardware` uses the compute guest's
      accelerator through its vendor's API (QSV on Intel); when the GPU is
      missing, transcodes fail visibly and direct play keeps working.
      `software` is the operator's fallback. Nothing changes the mode at
      runtime.
    '';
  };

  den.aspects.kubernetes.services.jellyfin.compute-resources =
    { cluster, ... }:
    let
      hostCompute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      linuxSystem =
        inputs.self.nixosConfigurations.${hostCompute.instance}.pkgs.stdenv.hostPlatform.system;
      packages = inputs.self.packages.${linuxSystem};
    in
    {
      images = [
        packages.jellyfin-provisioner-image
        packages.jellarr-image
      ];
      retainedPaths.jellyfin-config = {
        inherit (identity) uid gid;
        mode = "0750";
      };
      runtimeSecrets."jellyfin--jellyfin-admin--password" = {
        inherit namespace;
        name = integration.adminSecret.name;
        key = integration.adminSecret.key;
      };
    };

  den.aspects.kubernetes.services.jellyfin.k8s-manifests =
    {
      cluster,
      computeResources,
      ...
    }:
    let
      linuxSystem =
        inputs.self.nixosConfigurations.${computeResources.instance}.pkgs.stdenv.hostPlatform.system;
      packages = inputs.self.packages.${linuxSystem};
      provisioner = packages.jellyfin-provisioner-image;
      provisionerRelease = provisioner.passthru.release;
      jellarr = packages.jellarr-image;
      jellarrRelease = jellarr.passthru.release;
      provisionerImage = "${provisioner.imageName}:${provisioner.imageTag}";
      runtimeImage = "${provisionerRelease.runtimeImage}@${provisionerRelease.runtimeDigest}";
      jellarrImage = "${jellarrRelease.imageName}:${jellarrRelease.imageTag}";
      administrator = cluster.settings.kubernetes.services.jellyfin.administrator;
      transcoding = cluster.settings.kubernetes.services.jellyfin.transcoding;
      inherit (computeResources) accelerator;
      encoding =
        if transcoding == "software" then
          softwareEncoding
        else if accelerator == null then
          throw "Jellyfin declares hardware transcoding, but ${computeResources.instance} has no accelerator"
        else
          (hardwareEncoding accelerator.path).${accelerator.vendor};
      mediaPath = computeResources.mediaPaths.library;
      initialSeerr = cluster.settings.kubernetes.services.seerr.phase == "initial";
      route = cluster.routes.jellyfin;
      prefix = lib.optionalString (route.pathPrefix != "/") (lib.removeSuffix "/" route.pathPrefix);
      labels = {
        "app.kubernetes.io/controller" = "main";
        "app.kubernetes.io/instance" = "jellyfin";
        "app.kubernetes.io/name" = "jellyfin";
      };
      configurationLabels = {
        "app.kubernetes.io/instance" = "jellyfin-configuration";
        "app.kubernetes.io/name" = "jellarr";
      };
      podSecurity = {
        runAsUser = identity.uid;
        runAsGroup = identity.gid;
        runAsNonRoot = true;
        seccompProfile.type = "RuntimeDefault";
      };
      containerSecurity = podSecurity // {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
      };
      # JSON is valid YAML, and generating it keeps the libraries in one list.
      jellarrConfig = builtins.toJSON {
        version = 1;
        base_url = "http://${integration.host}:${toString integration.port}";
        system.enableMetrics = true;
        inherit encoding;
        library.virtualFolders = map (library: {
          inherit (library) name collectionType;
          libraryOptions.pathInfos = [ { path = "/media/${library.directory}"; } ];
        }) integration.libraries;
      };
      bootstrapScript = ''
        import fs from "node:fs";

        const baseUrl = process.env.JELLYFIN_URL;
        const password = fs.readFileSync("/run/secrets/password", "utf8").replace(/\r?\n$/, "");
        const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

        async function request(path, options = {}) {
          const response = await fetch(baseUrl + path, options);
          const body = await response.text();
          if (!response.ok) {
            throw new Error("Jellyfin API request failed: " + response.status);
          }
          return body.trim() === "" ? null : JSON.parse(body);
        }

        let healthy = false;
        for (let attempt = 0; attempt < 60; attempt += 1) {
          try {
            const response = await fetch(baseUrl + "/health");
            if (response.ok) {
              healthy = true;
              break;
            }
          } catch (_) {
            // The stock Service can exist before its Pod is ready.
          }
          await sleep(2000);
        }
        if (!healthy) {
          throw new Error("Jellyfin did not become healthy before the deadline");
        }

        const authentication = await request("/Users/AuthenticateByName", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: 'MediaBrowser Client="homelab-jellarr-bootstrap", Device="Kubernetes Job", DeviceId="jellarr-bootstrap", Version="1"',
          },
          body: JSON.stringify({ Username: process.env.JELLYFIN_ADMINISTRATOR, Pw: password }),
        });
        const administratorToken = authentication.AccessToken || authentication.accessToken;
        if (!administratorToken) {
          throw new Error("Jellyfin administrator authentication returned no token");
        }
        const headers = {
          "Content-Type": "application/json",
          Authorization: 'MediaBrowser Client="homelab-jellarr-bootstrap", Device="Kubernetes Job", DeviceId="jellarr-bootstrap", Version="1", Token="' + administratorToken + '"',
        };
        try {
          const keyName = "Jellarr";
          const namedKey = (response) =>
            (response.Items || response.items || []).filter(
              (key) => (key.AppName || key.appName) === keyName
            );
          let keys = namedKey(await request("/Auth/Keys", { headers }));
          if (keys.length > 1) {
            throw new Error("More than one Jellarr API key exists");
          }
          if (keys.length === 0) {
            await request("/Auth/Keys?app=Jellarr", { method: "POST", headers });
            keys = namedKey(await request("/Auth/Keys", { headers }));
          }
          if (keys.length !== 1) {
            throw new Error("Jellarr API key was not available after creation");
          }
          const apiKey = keys[0].AccessToken || keys[0].accessToken;
          if (!apiKey) {
            throw new Error("Jellarr API key response contained no token");
          }
          fs.writeFileSync("/run/jellarr/api-key", apiKey + "\n", { mode: 0o400 });
        } finally {
          try {
            await request("/Sessions/Logout", { method: "POST", headers });
          } catch (_) {
            // A failed logout must not hide a key-bootstrap failure.
          }
        }
      '';
    in
    assert lib.assertMsg (
      route.namespace == namespace
      && route.service == integration.service
      && route.port == integration.port
      && !route.backendTLS
    ) "Jellyfin route must target its declared HTTP Service";
    # One coupled release identity. The provisioner build must use the
    # declared source, the stock runtime tag must name the same version, and
    # the whole declaration must equal the reviewed release below. A Jellyfin
    # upgrade edits the package declaration, this reviewed release and the
    # acceptance evidence in one change; moving either side alone fails here.
    # modules/tests/jellyfin-contracts.nix proves each drift is rejected.
    assert lib.assertMsg (
      provisioner.passthru.provisioner.version == provisionerRelease.version
      && provisioner.passthru.provisioner.src.rev == provisionerRelease.sourceRev
    ) "Jellyfin provisioner build does not use the declared release source";
    assert lib.assertMsg (
      provisionerRelease.runtimeImage == "docker.io/jellyfin/jellyfin:${provisionerRelease.version}"
    ) "Jellyfin stock runtime image tag must equal the provisioner release version";
    assert lib.assertMsg (
      provisionerRelease == {
        version = "12.1";
        sourceRev = "ee91c75e777da41a9c4f4855e70adc604fbf2ef8";
        runtimeImage = "docker.io/jellyfin/jellyfin:12.1";
        runtimeDigest = "sha256:78d3ea1207d1322471fcac39a614f004f2ccf7e878f95ab2977d752f07e4dd7e";
        provisionPatchRev = "8b0a2c269d5a3d9d7084b5295fd818a8a67af6f2";
      }
    ) "Jellyfin release declaration differs from the reviewed coupled release";
    {
      applications.jellyfin-retained = {
        inherit namespace;
        retained = true;
        resources = {
          namespaces.jellyfin.metadata.annotations = retain;
          persistentVolumes.jellyfin-config = {
            metadata.annotations = retain;
            spec = {
              capacity.storage = "20Gi";
              accessModes = [ "ReadWriteOnce" ];
              persistentVolumeReclaimPolicy = "Retain";
              storageClassName = "";
              claimRef = {
                inherit namespace;
                name = "jellyfin-config";
              };
              local.path = computeResources.retainedPaths.jellyfin-config.guestPath;
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
          };
          persistentVolumeClaims.jellyfin-config = {
            metadata.annotations = retain;
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              storageClassName = "";
              volumeName = "jellyfin-config";
              resources.requests.storage = "20Gi";
            };
          };
        };
      };

      applications.jellyfin = {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "1";
        finalizer = "foreground";
        objects = [
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "jellyfin";
              inherit namespace labels;
            };
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels = labels;
              template = {
                metadata.labels = labels;
                spec = {
                  automountServiceAccountToken = false;
                  enableServiceLinks = false;
                  nodeSelector."kubernetes.io/hostname" = computeResources.instance;
                  securityContext = podSecurity // {
                    supplementalGroups = [
                      mediaGid
                      gpuRenderGid
                    ];
                  };
                  initContainers = [
                    {
                      name = "provision";
                      image = provisionerImage;
                      imagePullPolicy = "Never";
                      command = [ "/bin/jellyfin-provision" ];
                      env = [
                        {
                          name = "JELLYFIN_ADMINISTRATOR";
                          value = administrator;
                        }
                      ];
                      resources = {
                        requests = {
                          cpu = "50m";
                          memory = "64Mi";
                        };
                        limits = {
                          cpu = "1";
                          memory = "512Mi";
                          ephemeral-storage = "128Mi";
                        };
                      };
                      securityContext = containerSecurity;
                      volumeMounts = [
                        {
                          name = "config";
                          mountPath = "/config";
                        }
                        {
                          name = "cache";
                          mountPath = "/cache";
                        }
                        {
                          name = "provision";
                          mountPath = "/run/provision";
                        }
                        {
                          name = "admin-password";
                          mountPath = "/run/secrets/password";
                          subPath = "password";
                          readOnly = true;
                        }
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "jellyfin";
                      image = runtimeImage;
                      imagePullPolicy = "IfNotPresent";
                      # ffmpeg probing a new library alongside playback
                      # exceeded 2Gi and the kernel killed the server.
                      #
                      # Ephemeral storage is the cache emptyDir (see its
                      # sizeLimit below) plus this container's logs and
                      # writable layer. The limit adds 1Gi to the cache for
                      # logs and the writable layer, so the cache's own limit
                      # is what bounds the Pod.
                      #
                      # The request is a typical working set, not the whole
                      # cache. On this single-node cluster it only gates
                      # scheduling and ranks Pods for eviction when the node
                      # runs short of disk (below about 5% of nodefs free).
                      # The storage pool has far more free space than the
                      # 65Gi limit, so reserving all of it buys nothing, and a
                      # 64Gi request cannot schedule on a smaller node such
                      # as the 64 GiB prod-home-replacement fixture.
                      resources = {
                        requests = {
                          cpu = "500m";
                          memory = "1Gi";
                          ephemeral-storage = "8Gi";
                        };
                        limits = {
                          cpu = "2";
                          memory = "4Gi";
                          ephemeral-storage = "65Gi";
                        };
                      };
                      securityContext = containerSecurity;
                      startupProbe = {
                        httpGet = {
                          path = "${prefix}/Users/Public";
                          port = integration.port;
                        };
                        periodSeconds = 10;
                        timeoutSeconds = 5;
                        failureThreshold = 30;
                      };
                      readinessProbe = {
                        httpGet = {
                          path = "${prefix}/Users/Public";
                          port = integration.port;
                        };
                        periodSeconds = 10;
                        timeoutSeconds = 5;
                      };
                      livenessProbe = {
                        httpGet = {
                          path = "${prefix}/health";
                          port = integration.port;
                        };
                        periodSeconds = 30;
                        timeoutSeconds = 5;
                      };
                      volumeMounts = [
                        {
                          name = "config";
                          mountPath = "/config";
                        }
                        {
                          name = "cache";
                          mountPath = "/cache";
                        }
                        {
                          name = "media";
                          mountPath = "/media";
                          readOnly = true;
                          mountPropagation = "HostToContainer";
                        }
                        {
                          # Lets a running Pod see a node Incus adds later.
                          name = "dri";
                          mountPath = "/dev/dri";
                          mountPropagation = "HostToContainer";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "config";
                      persistentVolumeClaim.claimName = "jellyfin-config";
                    }
                    {
                      # Jellyfin writes transcodes to /cache/transcodes, its
                      # default. With throttling (300 s ahead) and segment
                      # deletion (900 s kept) set in Jellyfin, each stream
                      # holds at most about 1200 s of segments; Jellyfin
                      # throttles remuxes too. 64Gi holds four simultaneous
                      # 4K streams at remux-class bitrates (about 100 Mb/s,
                      # 14 GiB each) with headroom. Jellarr 0.1.0 cannot set
                      # those two options; docs/operations/jellyfin.md
                      # records them.
                      name = "cache";
                      emptyDir = {
                        sizeLimit = "64Gi";
                      };
                    }
                    {
                      name = "media";
                      hostPath = {
                        path = mediaPath;
                        type = "Directory";
                      };
                    }
                    {
                      # The guest creates /dev/dri at boot, so a missing GPU
                      # never blocks the Pod.
                      name = "dri";
                      hostPath = {
                        path = "/dev/dri";
                        type = "Directory";
                      };
                    }
                    {
                      name = "provision";
                      emptyDir = {
                        medium = "Memory";
                        sizeLimit = "16Mi";
                      };
                    }
                    {
                      name = "admin-password";
                      secret = {
                        secretName = integration.adminSecret.name;
                        defaultMode = 292;
                        items = [
                          {
                            key = integration.adminSecret.key;
                            path = "password";
                          }
                        ];
                      };
                    }
                  ];
                };
              };
            };
          }
          {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = integration.service;
              inherit namespace labels;
            };
            spec = {
              type = "ClusterIP";
              selector = labels;
              ports = [
                {
                  name = "http";
                  port = integration.port;
                  targetPort = integration.port;
                  protocol = "TCP";
                }
              ];
            };
          }
          {
            apiVersion = "networking.k8s.io/v1";
            kind = "NetworkPolicy";
            metadata = {
              name = "seerr-configuration-jellyfin-ingress";
              inherit namespace;
            };
            spec = {
              podSelector.matchLabels = labels;
              policyTypes = [ "Ingress" ];
              ingress = [
                {
                  from = [
                    {
                      namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "media";
                      podSelector.matchLabels."app.kubernetes.io/name" = "media-config-seerr";
                    }
                  ];
                  ports = [
                    {
                      protocol = "TCP";
                      port = integration.port;
                    }
                  ];
                }
              ];
            };
          }
          # The Jellarr configuration Job runs in this same namespace; once a
          # policy selects the Jellyfin pod, this Application must admit the
          # Job itself because the replacement fixture deploys Jellyfin without
          # the gateway app's backend policy.
          {
            apiVersion = "networking.k8s.io/v1";
            kind = "NetworkPolicy";
            metadata = {
              name = "jellyfin-configuration-ingress";
              inherit namespace;
            };
            spec = {
              podSelector.matchLabels = labels;
              policyTypes = [ "Ingress" ];
              ingress = [
                {
                  from = [
                    {
                      namespaceSelector.matchLabels."kubernetes.io/metadata.name" = namespace;
                      podSelector.matchLabels = configurationLabels;
                    }
                  ];
                  ports = [
                    {
                      protocol = "TCP";
                      port = integration.port;
                    }
                  ];
                }
              ];
            };
          }
        ] ++ lib.optionals initialSeerr [
          # Only the initial PostSync first-owner helper can read this Secret.
          # Ready-state helpers and every periodic run use an unprivileged SA.
          {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "Role";
            metadata = {
              name = "seerr-jellyfin-admin-reader";
              inherit namespace;
            };
            rules = [
              {
                apiGroups = [ "" ];
                resources = [ "secrets" ];
                resourceNames = [ integration.adminSecret.name ];
                verbs = [ "get" ];
              }
            ];
          }
          {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "RoleBinding";
            metadata = {
              name = "seerr-jellyfin-admin-reader";
              inherit namespace;
            };
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "Role";
              name = "seerr-jellyfin-admin-reader";
            };
            subjects = [
              {
                kind = "ServiceAccount";
                name = "media-config-seerr-bootstrap";
                namespace = "media";
              }
            ];
          }
        ];
      };

      applications.jellyfin-configuration = {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "2";
        finalizer = "foreground";
        objects = [
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "jellarr-configuration";
              inherit namespace;
            };
            data = {
              "config.yml" = jellarrConfig;
              "bootstrap.mjs" = bootstrapScript;
            };
          }
          {
            apiVersion = "batch/v1";
            kind = "Job";
            metadata = {
              name = "jellyfin-configuration";
              inherit namespace;
              labels = configurationLabels;
              annotations = {
                "argocd.argoproj.io/hook" = "PostSync";
                "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
                "homelab.danielvicory/jellarr-config" = builtins.hashString "sha256" jellarrConfig;
              };
            };
            spec = {
              backoffLimit = 4;
              activeDeadlineSeconds = 600;
              template = {
                metadata.labels = configurationLabels;
                spec = {
                  restartPolicy = "Never";
                  automountServiceAccountToken = false;
                  enableServiceLinks = false;
                  nodeSelector."kubernetes.io/hostname" = computeResources.instance;
                  securityContext = podSecurity // {
                    fsGroup = identity.gid;
                  };
                  initContainers = [
                    {
                      name = "bootstrap";
                      image = jellarrImage;
                      imagePullPolicy = "Never";
                      command = [ "node" ];
                      args = [ "/config/bootstrap.mjs" ];
                      env = [
                        {
                          name = "JELLYFIN_URL";
                          value = "http://${integration.host}:${toString integration.port}";
                        }
                        {
                          name = "JELLYFIN_ADMINISTRATOR";
                          value = administrator;
                        }
                      ];
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "32Mi";
                        };
                        limits = {
                          cpu = "250m";
                          memory = "128Mi";
                          ephemeral-storage = "64Mi";
                        };
                      };
                      securityContext = containerSecurity;
                      volumeMounts = [
                        {
                          name = "configuration";
                          mountPath = "/config";
                          readOnly = true;
                        }
                        {
                          name = "admin-password";
                          mountPath = "/run/secrets/password";
                          subPath = "password";
                          readOnly = true;
                        }
                        {
                          name = "api-key";
                          mountPath = "/run/jellarr";
                        }
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "jellarr";
                      image = jellarrImage;
                      imagePullPolicy = "Never";
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "32Mi";
                        };
                        limits = {
                          cpu = "500m";
                          memory = "256Mi";
                          ephemeral-storage = "128Mi";
                        };
                      };
                      securityContext = containerSecurity;
                      volumeMounts = [
                        {
                          name = "configuration";
                          mountPath = "/config";
                          readOnly = true;
                        }
                        {
                          name = "api-key";
                          mountPath = "/run/jellarr";
                          readOnly = true;
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "configuration";
                      configMap = {
                        name = "jellarr-configuration";
                        defaultMode = 292;
                      };
                    }
                    {
                      name = "admin-password";
                      secret = {
                        secretName = integration.adminSecret.name;
                        defaultMode = 288;
                        items = [
                          {
                            key = integration.adminSecret.key;
                            path = "password";
                          }
                        ];
                      };
                    }
                    {
                      name = "api-key";
                      emptyDir = {
                        medium = "Memory";
                        sizeLimit = "1Mi";
                      };
                    }
                  ];
                };
              };
            };
          }
        ];
      };
    };
}
