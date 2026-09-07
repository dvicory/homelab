{ ... }:
{
  den.aspects.kubernetes.services.gateway.k8s-manifests =
    { cluster, charts, lib, ... }:
    let
      namespace = "gateway";
      peers = cluster.ingress.trustedProxyCIDRs;
      retained = { "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false"; };
      object = apiVersion: kind: name: ns: spec: {
        inherit apiVersion kind spec;
        metadata = { inherit name; namespace = ns; };
      };
      target = kind: name: { group = "gateway.networking.k8s.io"; inherit kind name; };
      gatewayTarget = [ (target "Gateway" "household") ];
      proxySelector.matchLabels = {
        "gateway.envoyproxy.io/owning-gateway-namespace" = namespace;
        "gateway.envoyproxy.io/owning-gateway-name" = "household";
      };
      routes = lib.mapAttrsToList (name: route:
        object "gateway.networking.k8s.io/v1" "HTTPRoute" name namespace {
          parentRefs = [ { name = "household"; } ];
          inherit (route) hostnames;
          rules = [ {
            matches = [ { path = { type = "PathPrefix"; value = route.pathPrefix; }; } ];
            filters = [ { type = "RequestHeaderModifier"; requestHeaderModifier.remove = [
              "X-Forwarded-User" "X-Forwarded-Email" "X-Auth-Request-User" "X-Auth-Request-Email" "Remote-User" "Forwarded"
            ]; } ];
            backendRefs = [ { name = route.service; inherit (route) namespace port; } ];
          } ];
        }
      ) cluster.routes;
      adminPolicies = lib.mapAttrsToList (name: route:
        object "gateway.envoyproxy.io/v1alpha1" "SecurityPolicy" "${name}-admin" namespace {
          targetRefs = [ (target "HTTPRoute" name) ];
          # Authorization is performed by Kanidm's required scope map, not by
          # treating every successful OIDC login as an administrator.
          oidc = {
            provider = {
              # Kanidm has one canonical issuer; manual same-name DNS failover
              # keeps this endpoint valid when the normal edge is unavailable.
              issuer = "https://${builtins.head cluster.routes.idm.hostnames}/oauth2/openid/household-admin";
              authorizationEndpoint = "https://${builtins.head cluster.routes.idm.hostnames}/ui/oauth2";
              tokenEndpoint = "https://${builtins.head cluster.routes.idm.hostnames}/oauth2/token";
              backendRefs = [ {
                group = "gateway.envoyproxy.io";
                kind = "Backend";
                name = "kanidm-oidc";
                namespace = "identity";
                port = 8443;
              } ];
            };
            clientID = "household-admin";
            clientSecret.name = "oidc-client";
            # Operator must keep this client admin-only: map every requested
            # scope to homelab-admin; supplemental claims are not authorization.
            scopes = [ "openid" "profile" "email" "homelab_admin" ];
            redirectURL = "https://%REQ(:authority)%${lib.removeSuffix "/" route.pathPrefix}/oauth2/callback";
            logoutPath = "${lib.removeSuffix "/" route.pathPrefix}/logout";
            refreshToken = false;
            forwardAccessToken = false;
            passThroughAuthHeader = false;
          };
        }
      ) (lib.filterAttrs (_: r: r.auth == "admin") cluster.routes);
      backendGrants = lib.mapAttrsToList (name: route:
        object "gateway.networking.k8s.io/v1beta1" "ReferenceGrant" "gateway-${name}" route.namespace {
          from = [ { group = "gateway.networking.k8s.io"; kind = "HTTPRoute"; inherit namespace; } ];
          to = [ { group = ""; kind = "Service"; name = route.service; } ];
        }
      ) cluster.routes;
      oidcGrant = object "gateway.networking.k8s.io/v1beta1" "ReferenceGrant" "gateway-oidc-backend" "identity" {
        from = [ { group = "gateway.envoyproxy.io"; kind = "SecurityPolicy"; inherit namespace; } ];
        to = [ { group = "gateway.envoyproxy.io"; kind = "Backend"; name = "kanidm-oidc"; } ];
      };
      backendTLS = lib.mapAttrsToList (name: route:
        object "gateway.networking.k8s.io/v1" "BackendTLSPolicy" name route.namespace {
          targetRefs = [ { group = ""; kind = "Service"; name = route.service; } ];
          validation = {
            hostname = builtins.head route.hostnames;
            # The runtime Kanidm certificate must chain to a public CA. No
            # skip-verification fallback is permitted for private transport.
            wellKnownCACertificates = "System";
          };
        }
      ) (lib.filterAttrs (_: r: r.backendTLS) cluster.routes);
      backendIsolation =
        let
          namespaces = lib.unique (map (route: route.namespace) (builtins.attrValues cluster.routes));
        in
        map (ns:
          object "networking.k8s.io/v1" "NetworkPolicy" "gateway-backend-ingress" ns {
            podSelector = { };
            policyTypes = [ "Ingress" ];
            ingress = [
              { from = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = ns; } ]; }
              {
                from = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = namespace; podSelector = proxySelector; } ];
              }
            ]
            ++ lib.optional (ns == "jellyfin") {
              from = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "media"; } ];
              ports = [ { protocol = "TCP"; port = 8096; } ];
            }
            ++ lib.optional (ns != "monitoring") {
              from = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "monitoring"; } ];
            };
          }
        ) namespaces;
    in
    assert lib.assertMsg (cluster.routes.immich.pathPrefix == "/")
      "Gateway routes reject non-root Immich prefixes.";
    {
      applications.gateway-retained = {
        inherit namespace;
        objects = [ {
          apiVersion = "v1"; kind = "Namespace";
          metadata = { name = namespace; annotations = retained; };
        } ];
      };
      applications.gateway-crds = {
        inherit namespace;
        helm.releases.gateway-crds = {
          chart = charts.envoyproxy.gateway-crds-helm;
          values.crds = {
            gatewayAPI = { enabled = true; channel = "experimental"; };
            envoyGateway.enabled = true;
          };
        };
        syncPolicy.syncOptions.serverSideApply = true;
      };
      applications.gateway-controller = {
        inherit namespace;
        helm.releases.envoy-gateway = {
          chart = charts.envoyproxy.gateway-helm;
          values = {
            deployment.replicas = 1;
            config.envoyGateway = {
              provider.kubernetes.deploy.type = "GatewayNamespace";
              extensionApis.enableBackend = true;
            };
          };
        };
      };
      applications.gateway = {
        inherit namespace;
        objects = [
          {
            apiVersion = "gateway.networking.k8s.io/v1"; kind = "GatewayClass";
            metadata.name = "envoy";
            spec.controllerName = "gateway.envoyproxy.io/gatewayclass-controller";
          }
          (object "gateway.envoyproxy.io/v1alpha1" "EnvoyProxy" "household" namespace {
            provider = {
              type = "Kubernetes";
              kubernetes = {
                envoyDeployment = {
                  replicas = 1;
                  pod.nodeSelector."kubernetes.io/hostname" = cluster.nodeName;
                };
                envoyService = {
                  name = "household-origin";
                  type = "NodePort";
                  externalTrafficPolicy = "Local";
                  patch = {
                    type = "StrategicMerge";
                    value.spec.ports = [ {
                      name = "https";
                      port = 443;
                      targetPort = 8443;
                      nodePort = cluster.ingress.nodePort;
                    } ];
                  };
                };
              };
            };
          })
          (object "gateway.networking.k8s.io/v1" "Gateway" "household" namespace {
            gatewayClassName = "envoy";
            infrastructure.parametersRef = { group = "gateway.envoyproxy.io"; kind = "EnvoyProxy"; name = "household"; };
            listeners = [ {
              name = "https"; protocol = "HTTPS"; port = 443;
              allowedRoutes.namespaces.from = "Same";
              tls = { mode = "Terminate"; certificateRefs = [ { group = ""; kind = "Secret"; name = "gateway-tls"; } ]; };
            } ];
          })
          (object "gateway.envoyproxy.io/v1alpha1" "ClientTrafficPolicy" "trusted-edges" namespace {
            targetRefs = gatewayTarget;
            clientIPDetection = if peers == [ ] then { directSourceIP = { }; } else {
              xForwardedFor.trustedCIDRs = peers;
            };
          })
          (object "networking.k8s.io/v1" "NetworkPolicy" "private-origin" namespace {
            podSelector = proxySelector;
            policyTypes = [ "Ingress" ];
            ingress = lib.optional (peers != [ ]) {
              from = map (cidr: { ipBlock = { inherit cidr; }; }) peers;
              ports = [ { protocol = "TCP"; port = 8443; } ];
            };
          })
        ] ++ routes ++ adminPolicies ++ backendGrants ++ backendTLS ++ backendIsolation ++ [ oidcGrant ];
      };
    };
}
