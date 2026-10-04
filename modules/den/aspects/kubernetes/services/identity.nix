{
  config,
  inputs,
  lib,
  ...
}:
{
  den.aspects.kubernetes.services.identity.settings.phase = lib.mkOption {
    type = lib.types.enum [
      "initial"
      "provisioning"
      "normal"
    ];
    description = "Explicit Kanidm lifecycle phase; provisioning and normal require the recovered idm_admin credential.";
  };
  den.aspects.kubernetes.services.identity.settings.adminGroup = lib.mkOption {
    type = lib.types.str;
    default = "homelab-admin";
    description = "Kanidm group whose members administer Homelab. Provisioning fills it from the fleet `admins` role only in phase normal.";
  };
  den.aspects.kubernetes.services.identity.compute-resources =
    { cluster, ... }:
    let
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      guestSystem = inputs.self.nixosConfigurations.${compute.instance}.pkgs.stdenv.hostPlatform.system;
      activated = cluster.settings.kubernetes.services.identity.phase != "initial";
      idmAdminAge =
        inputs.self
        + "/.secrets/hosts/${compute.instance}/identity--kanidm-provision--idm-admin-password.age";
    in
    assert lib.assertMsg (
      !activated || builtins.pathExists idmAdminAge
    ) "Identity phases provisioning and normal require ${toString idmAdminAge}";
    {
      images = [ inputs.self.packages.${guestSystem}.kanidm-provision-image ];
      retainedPaths.identity-kanidm = {
        uid = 1000;
        gid = 1000;
        mode = "0700";
      };
      runtimeSecrets = {
      }
      // lib.optionalAttrs activated {
        "identity--kanidm-provision--idm-admin-password" = {
          namespace = "identity";
          name = "kanidm-provision";
          key = "idm-admin-password";
        };
      };
    };
  den.aspects.kubernetes.services.identity.k8s-manifests =
    {
      cluster,
      computeResources,
      lib,
      ...
    }:
    let
      namespace = "identity";
      phase = cluster.settings.kubernetes.services.identity.phase;
      activated = phase != "initial";
      normal = phase == "normal";
      provisionObjectNames = [ "kanidm-provision" ];
      domain = builtins.head cluster.routes.idm.hostnames;
      inherit (cluster.settings.kubernetes.services.identity) adminGroup;
      # Argo CD signs users in itself; its aspect owns the client settings.
      argocdOidc = cluster.settings.kubernetes.services.argocd.oidc;
      argocdRoute = cluster.routes.argocd;
      argocdUrls = map (hostname: "https://${hostname}") argocdRoute.hostnames;
      # Argo CD's callback path is fixed at /auth/callback, so Argo CD must
      # be served at the hostname root.
      argocdCallbacks =
        assert lib.assertMsg (
          argocdRoute.pathPrefix == "/"
        ) "Argo CD must be served at the hostname root for its /auth/callback path";
        map (url: "${url}/auth/callback") argocdUrls;
      clientName = "household-admin";
      clientSecretName = "oidc-client";
      # Every requested scope is restricted by this service's admin scope map.
      adminScopes = [
        "openid"
        "profile"
        "email"
        "homelab_admin"
      ];
      # The provisioning Job grants each client's scopes to adminGroup only
      # and publishes each Kanidm-generated client secret to its consumer.
      oauth2Clients = [
        {
          name = clientName;
          scopes = adminScopes;
          secret = {
            namespace = "gateway";
            name = clientSecretName;
            key = "client-secret";
            labels = { };
          };
        }
        {
          name = argocdOidc.clientName;
          inherit (argocdOidc) scopes;
          # Argo CD reads `$<name>:<key>` only from its own namespace and
          # only from a Secret labeled `app.kubernetes.io/part-of: argocd`.
          secret = {
            inherit (argocdRoute) namespace;
            name = argocdOidc.secretName;
            key = argocdOidc.secretKey;
            labels."app.kubernetes.io/part-of" = "argocd";
          };
        }
      ];
      # This Application declares each client Secret without data, so the
      # Job never needs `create`, which Kubernetes cannot limit by name.
      # Argo's server-side apply owns only metadata and type; the Job's
      # server-side apply (field manager identity-provisioner) owns `data`.
      # Fields owned by another manager produce no Argo drift.
      secretPublication = lib.concatMap (client: [
        {
          apiVersion = "v1";
          kind = "Secret";
          metadata = {
            inherit (client.secret) name namespace;
          }
          // lib.optionalAttrs (client.secret.labels != { }) { inherit (client.secret) labels; };
          type = "Opaque";
        }
        {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          metadata = {
            name = "kanidm-client-secret-${client.name}";
            inherit (client.secret) namespace;
          };
          rules = [
            {
              apiGroups = [ "" ];
              resources = [ "secrets" ];
              resourceNames = [ client.secret.name ];
              verbs = [
                "get"
                "patch"
              ];
            }
          ];
        }
        {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          metadata = {
            name = "kanidm-client-secret-${client.name}";
            inherit (client.secret) namespace;
          };
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "kanidm-client-secret-${client.name}";
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = "kanidm-provision";
              inherit namespace;
            }
          ];
        }
      ]) oauth2Clients;
      adminPolicies = lib.mapAttrsToList (name: route: {
        apiVersion = "gateway.envoyproxy.io/v1alpha1";
        kind = "SecurityPolicy";
        metadata = {
          name = "${name}-admin";
          namespace = "gateway";
        };
        spec = {
          targetRefs = [
            {
              group = "gateway.networking.k8s.io";
              kind = "HTTPRoute";
              inherit name;
            }
          ];
          oidc = {
            provider = {
              issuer = "https://${domain}/oauth2/openid/${clientName}";
              authorizationEndpoint = "https://${domain}/ui/oauth2";
              tokenEndpoint = "https://${domain}/oauth2/token";
              backendRefs = [
                {
                  group = "gateway.envoyproxy.io";
                  kind = "Backend";
                  name = "kanidm-oidc";
                  inherit namespace;
                  port = 443;
                  # Envoy Gateway's CRD default; Argo owns this list whole.
                  weight = 1;
                }
              ];
            };
            clientID = clientName;
            clientSecret.name = clientSecretName;
            scopes = adminScopes;
            redirectURL = "https://%REQ(:authority)%${lib.removeSuffix "/" route.pathPrefix}/oauth2/callback";
            logoutPath = "${lib.removeSuffix "/" route.pathPrefix}/logout";
            # Kanidm access tokens last 15 minutes. Renewing with the refresh
            # token keeps open pages and background streams working. Envoy
            # stores it encrypted and HMAC-signed in a session cookie.
            refreshToken = true;
            forwardAccessToken = false;
            passThroughAuthHeader = false;
          };
        };
      }) (lib.filterAttrs (_: route: route.auth == "admin") cluster.routes);
      # The image runs on the selected compute node, not on the renderer.
      linuxSystem =
        inputs.self.nixosConfigurations.${computeResources.instance}.pkgs.stdenv.hostPlatform.system;
      provisioning = inputs.self.packages.${linuxSystem}.kanidm-provision-image;
      registry = config.den.users.registry;
      administrators = lib.filterAttrs (
        name: _:
        builtins.elem "admins"
          (config.fleet.acl.get "env:${cluster.environment}" "resolveUser" name).allGroups
      ) registry;
      adminRoutes = builtins.attrValues (
        lib.filterAttrs (_: route: route.auth == "admin") cluster.routes
      );
      callbacks = lib.concatMap (
        route:
        map (
          hostname: "https://${hostname}${lib.removeSuffix "/" route.pathPrefix}/oauth2/callback"
        ) route.hostnames
      ) adminRoutes;
      # First-ever bootstrap is intentionally not a Job: the supported
      # recover-account flow runs in a private interactive session, prints
      # generated credentials there, and requires immediate escrow/encryption.
      # Publish only idm_admin's encrypted password in the runtime Secret. This
      # repeatable policy never resets recovery accounts or enrolls a user's
      # passkey.
      # Empty membership is deliberate: the final API operation grants the
      # resolved administrators only after MFA and client policy succeeds.
      provisionState = {
        groups.${adminGroup} = {
          members = [ ];
          overwriteMembers = true;
        };
        persons = lib.mapAttrs (name: user: {
          displayName = if user.identity.displayName != "" then user.identity.displayName else name;
          mailAddresses = lib.optional (user.identity.email != null) user.identity.email;
        }) administrators;
        # Scope maps stay empty here; the Job replaces them after this state.
        systems.oauth2 = {
          ${clientName} = {
            displayName = "Household administration";
            public = false;
            originUrl = callbacks;
            originLanding = "https://${builtins.head (builtins.head adminRoutes).hostnames}/";
            allowInsecureClientDisablePkce = false;
            preferShortUsername = true;
            scopeMaps = { };
            supplementaryScopeMaps = { };
            removeOrphanedClaimMaps = true;
          };
          # Argo CD signs users in itself; the Gateway gate stays in front.
          ${argocdOidc.clientName} = {
            displayName = "Argo CD";
            public = false;
            originUrl = argocdCallbacks;
            originLanding = "${builtins.head argocdUrls}/";
            allowInsecureClientDisablePkce = false;
            preferShortUsername = true;
            scopeMaps = { };
            supplementaryScopeMaps = { };
            removeOrphanedClaimMaps = true;
          };
        };
      };
      provisionLabels = {
        "app.kubernetes.io/name" = "kanidm-provision";
      };
      provisionSecurity = {
        allowPrivilegeEscalation = false;
        readOnlyRootFilesystem = true;
        capabilities.drop = [ "ALL" ];
      };
      protect = {
        "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
      };
      labels = {
        "app.kubernetes.io/name" = "kanidm";
      };
      gatewaySelector.matchLabels."gateway.envoyproxy.io/owning-gateway-name" = "household";
      image = "docker.io/kanidm/server:1.11.2@sha256:d87475bf9c9cfd24872d8b25957c9fc13fc090ace09ddc37c3b25fe394b397ac";
      # Kanidm's retained path and native export support are facts for Preserve.
      # Capture cadence, retention, targets, and restore policy belong there.
      serverConfig = ''
        version = "2"
        bindaddress = "0.0.0.0:8443"
        db_path = "/data/kanidm.db"
        tls_chain = "/etc/kanidm/tls/tls.crt"
        tls_key = "/etc/kanidm/tls/tls.key"
        domain = "${domain}"
        origin = "https://${domain}"
      '';
    in
    assert lib.assertMsg (
      cluster.routes.idm.namespace == namespace
      && cluster.routes.idm.service == "kanidm"
      && cluster.routes.idm.port == 443
      && cluster.routes.idm.backendTLS
      && cluster.routes.idm.backendHostname == domain
      && cluster.routes.idm.pathPrefix == "/"
    ) "Identity route must target the hostname-root HTTPS Service identity/kanidm:443";
    {
      # Contribute one identity-owned rewrite to the platform-owned ConfigMap.
      applications.cluster-dns.resources.configMaps.coredns-custom.data."kanidm.override" = ''
        rewrite name exact ${domain} kanidm.identity.svc.cluster.local
      '';
      applications.identity-gateway = lib.mkIf normal {
        namespace = "gateway";
        annotations."argocd.argoproj.io/sync-wave" = "4";
        finalizer = "foreground";
        objects =
          map (
            policy:
            policy
            // {
              metadata = policy.metadata // {
                annotations."argocd.argoproj.io/sync-wave" = "-1";
              };
            }
          ) adminPolicies
          ++ [
            # Transport health needs a route consumer; waiting in identity blocks PostSync.
            {
              apiVersion = "gateway.envoyproxy.io/v1alpha1";
              kind = "Backend";
              metadata = {
                name = "kanidm-oidc";
                inherit namespace;
              };
              spec.endpoints = [
                {
                  fqdn = {
                    hostname = "kanidm.identity.svc.cluster.local";
                    port = 443;
                  };
                }
              ];
            }
            {
              apiVersion = "gateway.networking.k8s.io/v1";
              kind = "BackendTLSPolicy";
              metadata = {
                name = "kanidm-oidc-tls";
                inherit namespace;
              };
              spec = {
                targetRefs = [
                  {
                    group = "gateway.envoyproxy.io";
                    kind = "Backend";
                    name = "kanidm-oidc";
                  }
                ];
                validation = {
                  hostname = domain;
                  wellKnownCACertificates = "System";
                };
              };
            }
            {
              apiVersion = "gateway.networking.k8s.io/v1beta1";
              kind = "ReferenceGrant";
              metadata = {
                name = "gateway-oidc-backend";
                inherit namespace;
              };
              spec = {
                from = [
                  {
                    group = "gateway.envoyproxy.io";
                    kind = "SecurityPolicy";
                    namespace = "gateway";
                  }
                ];
                to = [
                  {
                    group = "gateway.envoyproxy.io";
                    kind = "Backend";
                    name = "kanidm-oidc";
                  }
                ];
              };
            }
          ];
      };
      applications.identity-retained = {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "-2";
        retained = true;
        objects = [
          {
            apiVersion = "v1";
            kind = "Namespace";
            metadata = {
              name = namespace;
              annotations = protect;
            };
          }
        ];
        resources = {
          persistentVolumes.identity-kanidm = {
            metadata.annotations = protect;
            spec = {
              capacity.storage = "10Gi";
              accessModes = [ "ReadWriteOnce" ];
              storageClassName = "";
              local.path = computeResources.retainedPaths.identity-kanidm.guestPath;
              claimRef = {
                inherit namespace;
                name = "identity-kanidm";
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
          };
          persistentVolumeClaims.identity-kanidm = {
            metadata.annotations = protect;
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              storageClassName = "";
              volumeName = "identity-kanidm";
              resources.requests.storage = "10Gi";
            };
          };
        };
      };

      applications.identity = {
        inherit namespace;
        finalizer = "foreground";
        annotations."argocd.argoproj.io/sync-wave" = "2";
        objects =
          lib.filter (object: activated || !(builtins.elem object.metadata.name provisionObjectNames)) [
            {
              apiVersion = "v1";
              kind = "ConfigMap";
              metadata = {
                name = "kanidm-config";
                inherit namespace;
              };
              data."server.toml" = serverConfig;
            }
            {
              apiVersion = "apps/v1";
              kind = "Deployment";
              metadata = {
                name = "kanidm";
                inherit namespace;
                labels = labels;
              };
              spec = {
                replicas = 1;
                strategy.type = "Recreate";
                selector.matchLabels = labels;
                template = {
                  metadata.labels = labels;
                  spec = {
                    automountServiceAccountToken = false;
                    nodeSelector."kubernetes.io/hostname" = computeResources.instance;
                    securityContext = {
                      runAsNonRoot = true;
                      runAsUser = computeResources.retainedPaths.identity-kanidm.uid;
                      runAsGroup = computeResources.retainedPaths.identity-kanidm.gid;
                      seccompProfile.type = "RuntimeDefault";
                    };
                    containers = [
                      {
                        name = "kanidm";
                        image = image;
                        resources = {
                          requests = {
                            cpu = "100m";
                            memory = "256Mi";
                          };
                          limits = {
                            cpu = "2";
                            memory = "1Gi";
                          };
                        };
                        command = [ "/sbin/kanidmd" ];
                        args = [
                          "server"
                          "-c"
                          "/etc/kanidm/server.toml"
                        ];
                        ports = [
                          {
                            name = "https";
                            containerPort = 8443;
                          }
                        ];
                        readinessProbe = {
                          httpGet = {
                            scheme = "HTTPS";
                            port = "https";
                            path = "/status";
                          };
                          periodSeconds = 10;
                        };
                        livenessProbe = {
                          httpGet = {
                            scheme = "HTTPS";
                            port = "https";
                            path = "/status";
                          };
                          initialDelaySeconds = 30;
                          periodSeconds = 30;
                        };
                        securityContext = {
                          allowPrivilegeEscalation = false;
                          capabilities.drop = [ "ALL" ];
                        };
                        volumeMounts = [
                          {
                            name = "data";
                            mountPath = "/data";
                          }
                          {
                            name = "config";
                            mountPath = "/etc/kanidm/server.toml";
                            subPath = "server.toml";
                            readOnly = true;
                          }
                          {
                            name = "tls";
                            mountPath = "/etc/kanidm/tls";
                            readOnly = true;
                          }
                        ];
                      }
                    ];
                    volumes = [
                      {
                        name = "data";
                        persistentVolumeClaim.claimName = "identity-kanidm";
                      }
                      {
                        name = "config";
                        configMap.name = "kanidm-config";
                      }
                      {
                        name = "tls";
                        secret.secretName = "kanidm-tls";
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
                name = "kanidm";
                inherit namespace;
                labels = labels;
              };
              spec = {
                type = "ClusterIP";
                selector = labels;
                ports = [
                  {
                    name = "https";
                    port = 443;
                    targetPort = "https";
                    protocol = "TCP";
                  }
                ];
              };
            }
            {
              apiVersion = "networking.k8s.io/v1";
              kind = "NetworkPolicy";
              metadata = {
                name = "kanidm-private";
                inherit namespace;
              };
              spec = {
                podSelector.matchLabels = labels;
                policyTypes = [ "Ingress" ];
                ingress = [
                  {
                    from = [
                      {
                        namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "gateway";
                        podSelector = gatewaySelector;
                      }
                    ];
                    ports = [
                      {
                        protocol = "TCP";
                        port = 8443;
                      }
                    ];
                  }
                  {
                    from = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = namespace; } ];
                    ports = [
                      {
                        protocol = "TCP";
                        port = 8443;
                      }
                    ];
                  }
                ]
                # argocd-server fetches discovery and keys and redeems codes.
                # Cluster DNS rewrites the issuer hostname to the Service, so
                # this path never uses the host's public address.
                ++ lib.optional normal {
                  from = [
                    {
                      namespaceSelector.matchLabels."kubernetes.io/metadata.name" = argocdRoute.namespace;
                      podSelector.matchLabels = argocdRoute.backendPodSelector;
                    }
                  ];
                  ports = [
                    {
                      protocol = "TCP";
                      port = 8443;
                    }
                  ];
                };
              };
            }
            {
              apiVersion = "v1";
              kind = "ConfigMap";
              metadata = {
                name = "kanidm-provision";
                inherit namespace;
              };
              data = {
                "state.json" = builtins.toJSON provisionState;
                "clients.json" = builtins.toJSON oauth2Clients;
                "members.json" = builtins.toJSON (if normal then builtins.attrNames administrators else [ ]);
              };
            }
            {
              apiVersion = "v1";
              kind = "ServiceAccount";
              metadata = {
                name = "kanidm-provision";
                inherit namespace;
              };
              automountServiceAccountToken = false;
            }
            {
              apiVersion = "batch/v1";
              kind = "Job";
              metadata = {
                name = "kanidm-provision";
                inherit namespace;
                annotations = {
                  "argocd.argoproj.io/hook" = "PostSync";
                  "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
                };
              };
              spec = {
                backoffLimit = 6;
                activeDeadlineSeconds = 600;
                template = {
                  metadata.labels = provisionLabels;
                  spec = {
                    # Retain the pod IP while namespace network policy converges.
                    restartPolicy = "OnFailure";
                    serviceAccountName = "kanidm-provision";
                    automountServiceAccountToken = true;
                    nodeSelector."kubernetes.io/hostname" = computeResources.instance;
                    securityContext = {
                      runAsNonRoot = true;
                      runAsUser = 1000;
                      runAsGroup = 1000;
                      fsGroup = 1000;
                      seccompProfile.type = "RuntimeDefault";
                    };
                    containers = [
                      {
                        name = "provision";
                        image = provisioning.imageReference;
                        imagePullPolicy = "Never";
                        resources = {
                          requests = {
                            cpu = "50m";
                            memory = "64Mi";
                          };
                          limits = {
                            cpu = "1";
                            memory = "256Mi";
                          };
                        };
                        env = [
                          {
                            name = "KANIDM_URL";
                            value = "https://${domain}";
                          }
                          {
                            name = "KANIDM_ADMIN_GROUP";
                            value = adminGroup;
                          }
                          {
                            name = "HOME";
                            value = "/work";
                          }
                        ];
                        securityContext = provisionSecurity;
                        volumeMounts = [
                          {
                            name = "work";
                            mountPath = "/work";
                          }
                          {
                            name = "desired";
                            mountPath = "/desired";
                            readOnly = true;
                          }
                          {
                            name = "credentials";
                            mountPath = "/credentials";
                            readOnly = true;
                          }
                        ];
                      }
                    ];
                    volumes = [
                      {
                        name = "work";
                        emptyDir = {
                          medium = "Memory";
                          sizeLimit = "32Mi";
                        };
                      }
                      {
                        name = "desired";
                        configMap.name = "kanidm-provision";
                      }
                      {
                        name = "credentials";
                        secret = {
                          secretName = "kanidm-provision";
                          defaultMode = 288;
                          items = [
                            {
                              key = "idm-admin-password";
                              path = "idm-admin-password";
                            }
                          ];
                        };
                      }
                    ];
                  };
                };
              };
            }
          ]
          ++ lib.optionals activated secretPublication;
      };
    };
}
