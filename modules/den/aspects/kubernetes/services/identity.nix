{ config, inputs, lib, ... }:
{
  perSystem = { pkgs, system, ... }: lib.optionalAttrs (lib.hasSuffix "-linux" system) {
    packages.kanidm-provision-image = (import ./_identity-provisioning.nix { inherit pkgs lib; }).image;
  };
  den.aspects.kubernetes.services.identity.k8s-manifests =
    { cluster, pkgs, lib, ... }:
    let
      namespace = "identity";
      domain = builtins.head cluster.routes.idm.hostnames;
      linuxSystem = builtins.replaceStrings [ "darwin" ] [ "linux" ] pkgs.stdenv.hostPlatform.system;
      provisioning = import ./_identity-provisioning.nix {
        pkgs = inputs.nixpkgs.legacyPackages.${linuxSystem};
        inherit lib;
      };
      registry = config.den.users.registry;
      administrators = lib.filterAttrs (name: _:
        builtins.elem "admins"
          (config.fleet.acl.get "env:${cluster.environment}" "resolveUser" name).allGroups
      ) registry;
      adminRoutes = builtins.attrValues (lib.filterAttrs (_: route: route.auth == "admin") cluster.routes);
      callbacks = lib.concatMap (route:
        map (hostname: "https://${hostname}${lib.removeSuffix "/" route.pathPrefix}/oauth2/callback") route.hostnames
      ) adminRoutes;
      # First-ever bootstrap is intentionally not a Job: recover admin and
      # idm_admin with the stock server CLI, escrow both random passwords, and
      # publish only idm_admin's password in the runtime Secret. This repeatable
      # policy never resets recovery accounts or enrolls a user's passkey.
      # Empty membership is deliberate: the final API operation grants the
      # resolved administrators only after passkey and client policy succeeds.
      provisionState = {
        groups.homelab-admin = { members = [ ]; overwriteMembers = true; };
        persons = lib.mapAttrs (name: user: {
          displayName = if user.identity.displayName != "" then user.identity.displayName else name;
          mailAddresses = lib.optional (user.identity.email != null) user.identity.email;
        }) administrators;
        systems.oauth2.household-admin = {
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
      };
      provisionLabels = { "app.kubernetes.io/name" = "kanidm-provision"; };
      provisionSecurity = {
        allowPrivilegeEscalation = false;
        readOnlyRootFilesystem = true;
        capabilities.drop = [ "ALL" ];
      };
      protect = { "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false"; };
      labels = { "app.kubernetes.io/name" = "kanidm"; };
      gatewaySelector.matchLabels."gateway.envoyproxy.io/owning-gateway-name" = "household";
      image = "docker.io/kanidm/server:1.10.0@sha256:accd09b39511385b79e4318f238f197dce15ee828c853e63164a1f7826184327";
      serverConfig = ''
        version = "2"
        bindaddress = "0.0.0.0:8443"
        db_path = "/data/kanidm.db"
        tls_chain = "/etc/kanidm/tls/tls.crt"
        tls_key = "/etc/kanidm/tls/tls.key"
        domain = "${domain}"
        origin = "https://${domain}"
        [online_backup]
        path = "/data/backups/"
      '';
    in
    {
      applications.identity-retained = {
        inherit namespace;
        objects = [ {
          apiVersion = "v1";
          kind = "Namespace";
          metadata = { name = namespace; annotations = protect; };
        } ];
        resources = {
          persistentVolumes.identity-kanidm = {
            metadata.annotations = protect;
            spec = {
              capacity.storage = "10Gi";
              accessModes = [ "ReadWriteOnce" ];
              storageClassName = "";
              local.path = "${cluster.storageRoot}/identity/kanidm";
              claimRef = { inherit namespace; name = "identity-kanidm"; };
              nodeAffinity.required.nodeSelectorTerms = [ {
                matchExpressions = [ {
                  key = "kubernetes.io/hostname";
                  operator = "In";
                  values = [ cluster.nodeName ];
                } ];
              } ];
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
        annotations."argocd.argoproj.io/sync-wave" = "0";
        objects = [
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = { name = "kanidm-config"; inherit namespace; };
            data."server.toml" = serverConfig;
          }
          {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = { name = "kanidm"; inherit namespace; labels = labels; };
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels = labels;
              template = {
                metadata.labels = labels;
                spec = {
                  automountServiceAccountToken = false;
                  nodeSelector."kubernetes.io/hostname" = cluster.nodeName;
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 1000;
                    runAsGroup = 1000;
                    fsGroup = 1000;
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [ {
                    name = "kanidm";
                    image = image;
                    command = [ "/sbin/kanidmd" ];
                    args = [ "server" "-c" "/etc/kanidm/server.toml" ];
                    ports = [ { name = "https"; containerPort = 8443; } ];
                    readinessProbe = {
                      httpGet = { scheme = "HTTPS"; port = "https"; path = "/status"; };
                      periodSeconds = 10;
                    };
                    livenessProbe = {
                      httpGet = { scheme = "HTTPS"; port = "https"; path = "/status"; };
                      initialDelaySeconds = 30;
                      periodSeconds = 30;
                    };
                    securityContext = {
                      allowPrivilegeEscalation = false;
                      capabilities.drop = [ "ALL" ];
                    };
                    volumeMounts = [
                      { name = "data"; mountPath = "/data"; }
                      { name = "config"; mountPath = "/etc/kanidm/server.toml"; subPath = "server.toml"; readOnly = true; }
                      { name = "tls"; mountPath = "/etc/kanidm/tls"; readOnly = true; }
                    ];
                  } ];
                  volumes = [
                    { name = "data"; persistentVolumeClaim.claimName = "identity-kanidm"; }
                    { name = "config"; configMap.name = "kanidm-config"; }
                    { name = "tls"; secret.secretName = "kanidm-tls"; }
                  ];
                };
              };
            };
          }
          {
            apiVersion = "v1";
            kind = "Service";
            metadata = { name = "kanidm"; inherit namespace; labels = labels; };
            spec = {
              type = "ClusterIP";
              selector = labels;
              ports = [
                { name = "https"; port = 443; targetPort = "https"; protocol = "TCP"; }
                { name = "https-backend"; port = 8443; targetPort = "https"; protocol = "TCP"; }
              ];
            };
          }
          {
            apiVersion = "gateway.envoyproxy.io/v1alpha1";
            kind = "Backend";
            metadata = { name = "kanidm-oidc"; inherit namespace; };
            spec.endpoints = [ {
              fqdn = {
                hostname = "kanidm.identity.svc.cluster.local";
                port = 8443;
              };
            } ];
          }
          {
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "BackendTLSPolicy";
            metadata = { name = "kanidm-oidc-tls"; inherit namespace; };
            spec = {
              targetRefs = [ { group = "gateway.envoyproxy.io"; kind = "Backend"; name = "kanidm-oidc"; } ];
              validation = {
                hostname = domain;
                wellKnownCACertificates = "System";
              };
            };
          }
          {
            apiVersion = "networking.k8s.io/v1";
            kind = "NetworkPolicy";
            metadata = { name = "kanidm-private"; inherit namespace; };
            spec = {
              podSelector.matchLabels = labels;
              policyTypes = [ "Ingress" ];
              ingress = [
                { from = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "gateway"; podSelector = gatewaySelector; } ]; ports = [ { protocol = "TCP"; port = 8443; } ]; }
                { from = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = namespace; } ]; ports = [ { protocol = "TCP"; port = 8443; } ]; }
              ];
            };
          }
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = { name = "coredns-custom"; namespace = "kube-system"; };
            # K3s v1.35.8+k3s1 imports *.override in its root server block.
            # Exact rewrites also rewrite answers; issuer/TLS/passkey identity
            # stays canonical while in-cluster transport avoids the edge.
            data."kanidm.override" = ''
              rewrite name exact ${domain} kanidm.identity.svc.cluster.local
            '';
          }
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = { name = "kanidm-provision"; inherit namespace; };
            data = {
              "state.json" = builtins.toJSON provisionState;
              "members.json" = builtins.toJSON (builtins.attrNames administrators);
            };
          }
          {
            apiVersion = "v1";
            kind = "ServiceAccount";
            metadata = { name = "kanidm-provision"; inherit namespace; };
            automountServiceAccountToken = false;
          }
          {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "Role";
            metadata = { name = "kanidm-client-secret"; namespace = "gateway"; };
            rules = [
              # Kubernetes cannot constrain create by resourceNames. Updates
              # are limited to this one Secret; no read/list/delete permissions.
              { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "create" ]; }
              { apiGroups = [ "" ]; resources = [ "secrets" ]; resourceNames = [ "oidc-client" ]; verbs = [ "patch" ]; }
            ];
          }
          {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "RoleBinding";
            metadata = { name = "kanidm-client-secret"; namespace = "gateway"; };
            roleRef = { apiGroup = "rbac.authorization.k8s.io"; kind = "Role"; name = "kanidm-client-secret"; };
            subjects = [ { kind = "ServiceAccount"; name = "kanidm-provision"; inherit namespace; } ];
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
              backoffLimit = 2;
              activeDeadlineSeconds = 600;
              template = {
                metadata.labels = provisionLabels;
                spec = {
                  restartPolicy = "Never";
                  serviceAccountName = "kanidm-provision";
                  automountServiceAccountToken = true;
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 1000;
                    runAsGroup = 1000;
                    fsGroup = 1000;
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [ {
                    name = "provision";
                    image = provisioning.imageRef;
                    imagePullPolicy = "Never";
                    env = [
                      { name = "KANIDM_URL"; value = "https://${domain}"; }
                      { name = "HOME"; value = "/work"; }
                    ];
                    securityContext = provisionSecurity;
                    volumeMounts = [
                      { name = "work"; mountPath = "/work"; }
                      { name = "desired"; mountPath = "/desired"; readOnly = true; }
                      { name = "credentials"; mountPath = "/credentials"; readOnly = true; }
                    ];
                  } ];
                  volumes = [
                    { name = "work"; emptyDir = { medium = "Memory"; sizeLimit = "32Mi"; }; }
                    { name = "desired"; configMap.name = "kanidm-provision"; }
                    { name = "credentials"; secret = {
                      secretName = "kanidm-provision";
                      defaultMode = 288;
                      items = [ { key = "idm-admin-password"; path = "idm-admin-password"; } ];
                    }; }
                  ];
                };
              };
            };
          }
        ];
      };
    };
}
