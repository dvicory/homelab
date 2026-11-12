{ ... }:
{
  den.aspects.kubernetes.services.gateway.k8s-manifests =
    {
      cluster,
      computeResources,
      charts,
      lib,
      routes,
      ...
    }:
    let
      namespace = "gateway";
      public = cluster.ingress.public;
      ingressContract = import ../../../schema/_public-ingress.nix { inherit lib; };
      gatewayImage = "docker.io/envoyproxy/gateway:v1.9.1@sha256:0049bcb384c591c6a6dd043fe5c9929ef6e74f230e12dd678d2d3701df9b301e";
      proxyImage = "docker.io/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c13125d1629637cb4e4cce7207009fb7cc2c8027f9742758549d15b6f4";
      listenerPort = 443;
      # Envoy Gateway binds a privileged listener port (below 1024) at the
      # port plus 10000 inside the proxy pod, so the pod never needs
      # CAP_NET_BIND_SERVICE. Pod-level rules must use this port.
      proxyContainerPort = listenerPort + 10000;
      publicRouteEligible =
        name: route: public != null && route.exposure == "public" && (name != "idm" || identityNormal);
      identityNormal = cluster.settings.kubernetes.services.identity.phase == "normal";
      defaultTimeouts = {
        request = "15s";
        backendRequest = "15s";
      };
      publishedRoutes = lib.filterAttrs (
        name: route:
        route.auth != "admin"
        && (name != "requests" || cluster.settings.kubernetes.services.seerr.phase == "ready")
        && (
          name != "home" || (identityNormal && cluster.settings.kubernetes.services.homarr.phase == "ready")
        )
      ) routes;
      adminPublishedRoutes =
        if identityNormal then lib.filterAttrs (_: route: route.auth == "admin") routes else { };
      retained = {
        "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
      };
      object = apiVersion: kind: name: ns: spec: {
        inherit apiVersion kind spec;
        metadata = {
          inherit name;
          namespace = ns;
        };
      };
      target = kind: name: {
        group = "gateway.networking.k8s.io";
        inherit kind name;
      };
      proxySelector = name: {
        matchLabels = {
          "gateway.envoyproxy.io/owning-gateway-namespace" = namespace;
          "gateway.envoyproxy.io/owning-gateway-name" = name;
        };
      };
      backendPeers =
        name: route:
        map (gateway: {
          namespaceSelector.matchLabels."kubernetes.io/metadata.name" = namespace;
          podSelector = proxySelector gateway;
        }) ([ "household" ] ++ lib.optional (publicRouteEligible name route) "household-public");
      gatewayObjects = name: nodePort: [
        (object "gateway.envoyproxy.io/v1alpha1" "EnvoyProxy" name namespace {
          provider = {
            type = "Kubernetes";
            kubernetes = {
              envoyDeployment = {
                replicas = 1;
                container.image = proxyImage;
                pod.nodeSelector."kubernetes.io/hostname" = computeResources.instance;
              };
              envoyService = {
                name = "${name}-origin";
                type = "NodePort";
                externalTrafficPolicy = "Local";
                patch = {
                  type = "StrategicMerge";
                  value.spec.ports = [
                    {
                      name = "https";
                      port = listenerPort;
                      inherit nodePort;
                    }
                  ];
                };
              };
            };
          };
          # Stock OAuth2 diagnostics can include credential material.
          logging.level = {
            default = "warn";
            oauth2 = "critical";
          };
          telemetry.accessLog.settings = [
            {
              format = {
                type = "JSON";
                json = {
                  timestamp = "%START_TIME%";
                  client = "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%";
                  method = "%REQ(:METHOD)%";
                  path = "%PATH(NQ)%";
                  host = "%REQ(:AUTHORITY)%";
                  status = "%RESPONSE_CODE%";
                  duration_ms = "%DURATION%";
                  request_id = "%REQ(X-REQUEST-ID)%";
                  response_flags = "%RESPONSE_FLAGS%";
                  upstream = "%UPSTREAM_HOST%";
                };
              };
              sinks = [
                {
                  type = "File";
                  file.path = "/dev/stdout";
                }
              ];
            }
          ];
        })
        (object "gateway.networking.k8s.io/v1" "Gateway" name namespace {
          gatewayClassName = "envoy";
          infrastructure.parametersRef = {
            group = "gateway.envoyproxy.io";
            kind = "EnvoyProxy";
            inherit name;
          };
          listeners = [
            {
              name = "https";
              protocol = "HTTPS";
              port = listenerPort;
              allowedRoutes.namespaces.from = "Same";
              tls = {
                mode = "Terminate";
                certificateRefs = [
                  {
                    group = "";
                    kind = "Secret";
                    name = "gateway-tls";
                  }
                  {
                    group = "";
                    kind = "Secret";
                    namespace = routes.idm.namespace;
                    name = "kanidm-tls";
                  }
                ];
              };
            }
          ];
        })
      ];
      trafficPolicy =
        name: gateway:
        object "gateway.envoyproxy.io/v1alpha1" "ClientTrafficPolicy" name namespace (
          {
            targetRefs = [ (target "Gateway" gateway) ];
            clientIPDetection.directSourceIP = { };
            headers = {
              requestID = "Generate";
              xForwardedClientCert.mode = "Sanitize";
              # Sanitize before Envoy reconstructs forwarding metadata and IDs,
              # not in a route filter that would strip the reconstructed values.
              earlyRequestHeaders.remove = [
                "Forwarded"
                "X-Forwarded-For"
                "X-Forwarded-Host"
                "X-Forwarded-Proto"
                "X-Forwarded-Port"
                "X-Forwarded-Server"
                "X-Real-IP"
                "X-Forwarded-User"
                "X-Forwarded-Email"
                "X-Auth-Request-User"
                "X-Auth-Request-Email"
                "Remote-User"
                "X-Request-ID"
                "X-Correlation-ID"
                "X-Client-Request-ID"
                "X-Envoy-External-Address"
                "X-Envoy-Internal"
              ];
            };
          }
          // lib.optionalAttrs (gateway == "household-public") {
            # No direct-TLS fallback on the peer-only receiver.
            proxyProtocol.optional = false;
          }
        );
      routeObjects =
        routeSet:
        lib.mapAttrsToList (
          name: route:
          let
            timeouts = if route.timeouts == null then defaultTimeouts else route.timeouts;
          in
          object "gateway.networking.k8s.io/v1" "HTTPRoute" name namespace {
            # Argo CD owns parentRefs, rules and backendRefs as whole atomic
            # lists and compares them without CRD defaults. Spell out every
            # Gateway API v1.6.1 default inside them (group, kind, weight), or
            # the API server's defaults show up as permanent OutOfSync.
            parentRefs = [
              {
                group = "gateway.networking.k8s.io";
                kind = "Gateway";
                name = "household";
              }
            ]
            ++ lib.optional (publicRouteEligible name route) {
              group = "gateway.networking.k8s.io";
              kind = "Gateway";
              name = "household-public";
            };
            inherit (route) hostnames;
            rules = [
              {
                matches = [
                  {
                    path = {
                      type = "PathPrefix";
                      value = route.pathPrefix;
                    };
                  }
                ];
                inherit timeouts;
                backendRefs = [
                  {
                    group = "";
                    kind = "Service";
                    name = route.service;
                    inherit (route) namespace port;
                    weight = 1;
                  }
                ];
              }
            ];
          }
        ) routeSet;
      grantObjects =
        routeSet:
        lib.mapAttrsToList (
          name: route:
          object "gateway.networking.k8s.io/v1beta1" "ReferenceGrant" "gateway-${name}" route.namespace {
            from = [
              {
                group = "gateway.networking.k8s.io";
                kind = "HTTPRoute";
                inherit namespace;
              }
            ];
            to = [
              {
                group = "";
                kind = "Service";
                name = route.service;
              }
            ];
          }
        ) routeSet;
      tlsObjects =
        routeSet:
        lib.mapAttrsToList (
          name: route:
          object "gateway.networking.k8s.io/v1" "BackendTLSPolicy" name route.namespace {
            targetRefs = [
              {
                group = "";
                kind = "Service";
                name = route.service;
              }
            ];
            validation = {
              hostname = route.backendHostname;
              wellKnownCACertificates = "System";
            };
          }
        ) (lib.filterAttrs (_: route: route.backendTLS) routeSet);
      isolationObjects =
        routeSet:
        lib.mapAttrsToList (
          name: route:
          object "networking.k8s.io/v1" "NetworkPolicy" "gateway-${name}-backend-ingress" route.namespace {
            podSelector.matchLabels = route.backendPodSelector;
            policyTypes = [ "Ingress" ];
            # This policy isolates the backend, so by default it keeps the
            # backend open to its own namespace, where its in-cluster clients
            # usually run. A route with sameNamespaceIngress = false leaves
            # those clients to the backend owner's own policy.
            ingress =
              lib.optional route.sameNamespaceIngress {
                from = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = route.namespace; } ];
              }
              ++ [
                {
                  from = backendPeers name route;
                }
              ];
          }
        ) (lib.filterAttrs (_: route: route.manageBackendIngress) routeSet);
      publishedRouteObjects = routeObjects publishedRoutes;
      backendGrants = grantObjects publishedRoutes;
      backendTLS = tlsObjects publishedRoutes;
      backendIsolation = isolationObjects publishedRoutes;
      adminObjects =
        map
          (
            resource:
            if resource.kind == "HTTPRoute" then
              resource
              // {
                metadata = resource.metadata // {
                  annotations."argocd.argoproj.io/sync-wave" = "0";
                };
              }
            else
              resource
          )
          (
            routeObjects adminPublishedRoutes
            ++ grantObjects adminPublishedRoutes
            ++ tlsObjects adminPublishedRoutes
            ++ isolationObjects adminPublishedRoutes
          );
      backendSelectorsValid = lib.all (
        route: route ? backendPodSelector && route.backendPodSelector != { }
      ) (builtins.attrValues routes);
    in
    assert lib.assertMsg backendSelectorsValid "Gateway routes require a non-empty backendPodSelector";
    assert lib.assertMsg (lib.all (route: !route.backendTLS || route.backendHostname != null) (
      builtins.attrValues routes
    )) "TLS Gateway routes require backendHostname";
    assert lib.assertMsg (ingressContract.valid cluster.ingress)
      "Gateway ingress requires distinct NodePorts, distinct guest/relay Tailnet IPv4 addresses and the relay's Tailnet IPv6 address";
    {
      applications.gateway-retained = {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "-2";
        retained = true;
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
      };
      applications.gateway-crds = {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "0";
        finalizer = "foreground";
        helm.releases.gateway-crds = {
          chart = charts.envoyproxy.gateway-crds-helm;
          values.crds = {
            gatewayAPI = {
              enabled = true;
              channel = "experimental";
            };
            envoyGateway.enabled = true;
          };
        };
        syncPolicy.syncOptions.serverSideApply = true;
      };
      applications.gateway-controller = {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "1";
        finalizer = "foreground";
        helm.releases.envoy-gateway = {
          chart = charts.envoyproxy.gateway-helm;
          includeCRDs = false;
          values = {
            crds.enabled = false;
            global.images = {
              envoyGateway.image = gatewayImage;
              envoyProxy.image = proxyImage;
            };
            deployment.replicas = 1;
            config.envoyGateway = {
              provider.kubernetes.deploy.type = "GatewayNamespace";
              provider.kubernetes.shutdownManager.image = gatewayImage;
              extensionApis.enableBackend = true;
            };
          };
        };
      };
      applications.identity-gateway = lib.mkIf identityNormal {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "4";
        finalizer = "foreground";
        objects = adminObjects;
      };
      applications.gateway = {
        inherit namespace;
        annotations."argocd.argoproj.io/sync-wave" = "3";
        finalizer = "foreground";
        objects = [
          {
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "GatewayClass";
            metadata.name = "envoy";
            spec.controllerName = "gateway.envoyproxy.io/gatewayclass-controller";
          }
          (object "gateway.networking.k8s.io/v1beta1" "ReferenceGrant" "gateway-identity-certificate"
            routes.idm.namespace
            {
              from = [
                {
                  group = "gateway.networking.k8s.io";
                  kind = "Gateway";
                  inherit namespace;
                }
              ];
              to = [
                {
                  group = "";
                  kind = "Secret";
                  name = "kanidm-tls";
                }
              ];
            }
          )
          (trafficPolicy "private-origin" "household")
        ]
        ++ gatewayObjects "household" cluster.ingress.nodePort
        ++ lib.optionals (public != null) (
          gatewayObjects "household-public" public.nodePort
          ++ [
            (trafficPolicy "public-origin" "household-public")
            (object "networking.k8s.io/v1" "NetworkPolicy" "public-origin" namespace {
              podSelector = proxySelector "household-public";
              policyTypes = [ "Ingress" ];
              ingress = [
                {
                  from = [ { ipBlock.cidr = "${public.peerAddress}/32"; } ];
                  ports = [
                    {
                      protocol = "TCP";
                      port = proxyContainerPort;
                    }
                  ];
                }
              ];
            })
          ]
        )
        ++ publishedRouteObjects
        ++ backendGrants
        ++ backendTLS
        ++ backendIsolation;
      };
    };
}
