{
  config,
  inputs,
  lib,
  ...
}:
let
  flakeConfig = config;
in
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
  den.aspects.kubernetes.services.identity.settings.householdGroup = lib.mkOption {
    type = lib.types.strMatching "[a-z][a-z0-9_-]*";
    default = "jellyfin-users";
    description = ''
      Kanidm group whose members may sign in to Jellyfin, and through it to
      Seerr, with their Kanidm password. Provisioning creates the group and
      its account policy; operators manage its members in Kanidm.
    '';
  };
  den.aspects.kubernetes.services.identity.settings.directory = lib.mkOption {
    type = lib.types.attrs;
    readOnly = true;
    default = {
      port = 3636;
    };
    description = "Read-only port of Kanidm's LDAPS gateway on its Service, for directory consumers.";
  };
  den.aspects.kubernetes.services.identity.route-metadata =
    { cluster, ... }:
    {
      routes.idm = lib.mapAttrs (_: lib.mkDefault) {
        namespace = "identity";
        service = "kanidm";
        port = 443;
        backendPodSelector."app.kubernetes.io/name" = "kanidm";
        backendTLS = true;
        backendHostname = builtins.head cluster.routes.idm.hostnames;
      };
    };
  den.aspects.kubernetes.services.identity.compute-resources =
    { cluster, ... }:
    let
      compute =
        flakeConfig.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      activated = cluster.settings.kubernetes.services.identity.phase != "initial";
      idmAdminAge =
        inputs.self
        + "/.secrets/hosts/${compute.instance}/identity--kanidm-provision--idm-admin-password.age";
    in
    assert lib.assertMsg (
      !activated || builtins.pathExists idmAdminAge
    ) "Identity phases provisioning and normal require ${toString idmAdminAge}";
    {
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
      config,
      computeResources,
      lib,
      routes,
      ...
    }:
    let
      namespace = "identity";
      phase = cluster.settings.kubernetes.services.identity.phase;
      activated = phase != "initial";
      normal = phase == "normal";
      provisionObjectNames = [ "kanidm-provision" ];
      domain = builtins.head routes.idm.hostnames;
      inherit (cluster.settings.kubernetes.services.identity) adminGroup householdGroup directory;
      jellyfinRoute = routes.jellyfin;
      adminRoutes = lib.filterAttrs (_: route: route.auth == "admin-gateway") routes;
      routeUrls =
        route:
        map (hostname: "https://${hostname}${lib.removeSuffix "/" route.pathPrefix}") route.hostnames;
      gatewaySecret = name: {
        namespace = "gateway";
        name = "oidc-${name}";
        key = "client-secret";
        labels = { };
      };
      appsByRoute = lib.listToAttrs (
        lib.mapAttrsToList (_: app: lib.nameValuePair app.routeKey app) config.oidcClients
      );
      clients =
        assert lib.assertMsg (
          lib.length (lib.unique (map (app: app.clientID) (lib.attrValues config.oidcClients)))
          == lib.length (lib.attrValues config.oidcClients)
        ) "OIDC applications must have distinct client IDs";
        assert lib.assertMsg (
          builtins.length (builtins.attrNames appsByRoute)
          == builtins.length (builtins.attrNames config.oidcClients)
        ) "Each route must have at most one OIDC application";
        lib.mapAttrs' (
          _: app:
          let
            route = routes.${app.routeKey};
            urls = routeUrls route;
            admin = route.auth == "admin-gateway";
            native = app.callbackPath != null;
            displayName = if app.displayName == null then route.displayName else app.displayName;
          in
          assert lib.assertMsg (displayName != null) "OIDC application ${app.clientID} needs a display name";
          assert lib.assertMsg (
            !admin || app.eligibleGroup == adminGroup
          ) "Administrator OIDC application ${app.clientID} must use ${adminGroup}";
          assert lib.assertMsg (
            native == (app.secret != null)
          ) "Native OIDC application ${app.clientID} needs both a callback and a client Secret";
          assert lib.assertMsg (
            !native || route.pathPrefix == "/"
          ) "Native OIDC application ${app.clientID} must be served at the hostname root";
          lib.nameValuePair app.clientID {
            inherit displayName;
            landing = "${builtins.head urls}${app.landingPath}";
            redirects =
              lib.optionals admin (map (url: "${url}/oauth2/callback") urls)
              ++ lib.optionals native (map (url: "${url}${app.callbackPath}") urls);
            inherit (app) eligibleGroup scopes;
            secrets =
              lib.optional admin (gatewaySecret app.routeKey)
              ++ lib.optional native (app.secret // { inherit (route) namespace; });
          }
        ) config.oidcClients;
      # The provisioning Job grants each client's scopes to its eligibleGroup,
      # publishes each Kanidm-generated client secret to every listed Secret,
      # and deletes Kanidm clients that this list does not name.
      oauth2Clients = lib.mapAttrsToList (name: client: {
        inherit name;
        inherit (client) eligibleGroup scopes secrets;
      }) clients;
      # GitOps owns metadata and type; identity-provisioner owns data.
      # Predeclare Secrets: Kubernetes cannot restrict `create` by name.
      secretPublication = lib.concatMap (secret: [
        {
          apiVersion = "v1";
          kind = "Secret";
          metadata = {
            inherit (secret) name namespace;
          }
          // lib.optionalAttrs (secret.labels != { }) { inherit (secret) labels; };
          type = "Opaque";
        }
        {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          metadata = {
            name = "kanidm-client-secret-${secret.name}";
            inherit (secret) namespace;
          };
          rules = [
            {
              apiGroups = [ "" ];
              resources = [ "secrets" ];
              resourceNames = [ secret.name ];
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
            name = "kanidm-client-secret-${secret.name}";
            inherit (secret) namespace;
          };
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "kanidm-client-secret-${secret.name}";
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = "kanidm-provision";
              inherit namespace;
            }
          ];
        }
      ]) (lib.concatMap (client: client.secrets) oauth2Clients);
      adminPolicies = lib.mapAttrsToList (
        name: route:
        let
          clientID = appsByRoute.${name}.clientID;
        in
        {
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
                issuer = "https://${domain}/oauth2/openid/${clientID}";
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
              inherit clientID;
              clientSecret.name = (gatewaySecret name).name;
              # Kanidm remembers one exact consent scope set per client.
              # The entrance and native app must request the same set.
              scopes = clients.${clientID}.scopes;
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
        }
      ) adminRoutes;
      # The image runs on the selected compute node, not on the renderer.
      linuxSystem =
        inputs.self.nixosConfigurations.${computeResources.instance}.pkgs.stdenv.hostPlatform.system;
      selected = builtins.fromJSON (
        builtins.readFile (inputs.self + "/assets/helper-release/verified.json")
      );
      provisioning = selected.artifacts.kanidm-provision-image;
      provisioningImage = "${provisioning.repository}@${provisioning.digest}";
      registry = flakeConfig.den.users.registry;
      administrators = lib.filterAttrs (
        name: _:
        builtins.elem "admins"
          (flakeConfig.fleet.acl.get "env:${cluster.environment}" "resolveUser" name).allGroups
      ) registry;
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
        # Household members are not fleet users; operators add them in Kanidm.
        groups.${householdGroup} = {
          members = [ ];
          overwriteMembers = false;
        };
        # One eligibility group reuses the provisioner's single-group scope
        # map. Nested membership admits both audiences without granting admin.
        groups.homarr-users = {
          members = [
            adminGroup
            householdGroup
          ];
          overwriteMembers = true;
        };
        persons = lib.mapAttrs (name: user: {
          displayName = if user.identity.displayName != "" then user.identity.displayName else name;
          mailAddresses = lib.optional (user.identity.email != null) user.identity.email;
        }) administrators;
        # Scope maps stay empty here; the Job replaces them after this state.
        systems.oauth2 = lib.mapAttrs (_: client: {
          inherit (client) displayName;
          public = false;
          originUrl = client.redirects;
          originLanding = client.landing;
          allowInsecureClientDisablePkce = false;
          preferShortUsername = true;
          scopeMaps = { };
          supplementaryScopeMaps = { };
          removeOrphanedClaimMaps = true;
        }) clients;
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
        ldapbindaddress = "0.0.0.0:${toString directory.port}"
      '';
      # A missing revision must block startup, never bind an older subPath file.
      serverConfigName = "kanidm-config-${builtins.hashString "sha256" serverConfig}";
      # Account policy per group. Kanidm applies the strictest value of each
      # setting across a person's groups, so the administrator group states
      # its own minimum instead of relying on Kanidm's default, and a
      # household member's password-only credential needs the all-persons
      # floor lowered to `any`. Primary-password fallback lets a household
      # member's one Kanidm password work for LDAP binds; administrators
      # bind only with a separate POSIX password.
      accountPolicies = [
        {
          group = "idm_all_persons";
          credentialTypeMinimum = "any";
          allowPrimaryCredFallback = null;
        }
        {
          group = adminGroup;
          credentialTypeMinimum = "mfa";
          allowPrimaryCredFallback = false;
        }
        {
          group = householdGroup;
          credentialTypeMinimum = "any";
          allowPrimaryCredFallback = true;
        }
      ];
    in
    assert lib.assertMsg (
      selected.system == linuxSystem
    ) "Selected helper release must target the identity compute guest's system";
    assert lib.assertMsg (
      routes.idm.namespace == namespace
      && routes.idm.service == "kanidm"
      && routes.idm.port == 443
      && routes.idm.backendTLS
      && routes.idm.backendHostname == domain
      && routes.idm.pathPrefix == "/"
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
                name = serverConfigName;
                inherit namespace;
              };
              data."server.toml" = serverConfig;
              immutable = true;
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
                          {
                            name = "ldaps";
                            containerPort = directory.port;
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
                        configMap.name = serverConfigName;
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
                  {
                    name = "ldaps";
                    port = directory.port;
                    targetPort = "ldaps";
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
                # Jellyfin's LDAP plugin is the only directory client. Cluster
                # DNS rewrites the identity hostname to the Service.
                ++ [
                  {
                    from = [
                      {
                        namespaceSelector.matchLabels."kubernetes.io/metadata.name" = jellyfinRoute.namespace;
                        podSelector.matchLabels = jellyfinRoute.backendPodSelector;
                      }
                    ];
                    ports = [
                      {
                        protocol = "TCP";
                        port = directory.port;
                      }
                    ];
                  }
                ]
                # Native OIDC apps fetch discovery, redeem codes and read user
                # information through the identity Service's DNS rewrite.
                ++ lib.optionals normal (
                  map (
                    app:
                    let
                      route = routes.${app.routeKey};
                    in
                    {
                      from = [
                        {
                          namespaceSelector.matchLabels."kubernetes.io/metadata.name" = route.namespace;
                          podSelector.matchLabels = route.backendPodSelector;
                        }
                      ];
                      ports = [
                        {
                          protocol = "TCP";
                          port = 8443;
                        }
                      ];
                    }
                  ) (lib.filter (app: app.callbackPath != null) (lib.attrValues config.oidcClients))
                );
              };
            }
            {
              apiVersion = "v1";
              kind = "ConfigMap";
              metadata = {
                name = "kanidm-provision";
                inherit namespace;
                annotations."homelab.danielvicory/helper-image" = provisioningImage;
              };
              data = {
                "state.json" = builtins.toJSON provisionState;
                "clients.json" = builtins.toJSON oauth2Clients;
                "members.json" = builtins.toJSON (if normal then builtins.attrNames administrators else [ ]);
                "policies.json" = builtins.toJSON accountPolicies;
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
                        image = provisioningImage;
                        imagePullPolicy = "IfNotPresent";
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
