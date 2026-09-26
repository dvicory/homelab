{ ... }:
{
  den.aspects.kubernetes.services.gateway.k8s-manifests =
    {
      cluster,
      computeResources,
      charts,
      lib,
      ...
    }:
    let
      namespace = "gateway";
      peers = cluster.ingress.trustedProxyCIDRs;
      gatewayImage = "docker.io/envoyproxy/gateway:v1.9.1@sha256:0049bcb384c591c6a6dd043fe5c9929ef6e74f230e12dd678d2d3701df9b301e";
      proxyImage = "docker.io/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c13125d1629637cb4e4cce7207009fb7cc2c8027f9742758549d15b6f4";
      originModeValid =
        (cluster.ingress.mode == "direct" && peers == [ ])
        || (cluster.ingress.mode == "trustedEdges" && peers != [ ]);
      identityNormal = cluster.settings.kubernetes.services.identity.phase == "normal";
      defaultTimeouts = {
        request = "15s";
        backendRequest = "15s";
      };
      publishedRoutes = lib.filterAttrs (
        name: route:
        route.auth != "admin"
        && (name != "requests" || cluster.settings.kubernetes.services.seerr.phase == "ready")
      ) cluster.routes;
      adminPublishedRoutes =
        if identityNormal then lib.filterAttrs (_: route: route.auth == "admin") cluster.routes else { };
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
      gatewayTarget = [ (target "Gateway" "household") ];
      proxySelector.matchLabels = {
        "gateway.envoyproxy.io/owning-gateway-namespace" = namespace;
        "gateway.envoyproxy.io/owning-gateway-name" = "household";
      };
      routeObjects =
        routeSet:
        lib.mapAttrsToList (
          name: route:
          let
            timeouts = if route.timeouts == null then defaultTimeouts else route.timeouts;
          in
          object "gateway.networking.k8s.io/v1" "HTTPRoute" name namespace {
            parentRefs = [ { name = "household"; } ];
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
                filters = [
                  {
                    type = "RequestHeaderModifier";
                    requestHeaderModifier.remove = [
                      "X-Real-IP"
                      "X-Forwarded-User"
                      "X-Forwarded-Email"
                      "X-Auth-Request-User"
                      "X-Auth-Request-Email"
                      "Remote-User"
                      "Forwarded"
                    ];
                  }
                ];
                backendRefs = [
                  {
                    name = route.service;
                    inherit (route) namespace port;
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
            ingress = [
              { from = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = route.namespace; } ]; }
              {
                from = [
                  {
                    namespaceSelector.matchLabels."kubernetes.io/metadata.name" = namespace;
                    podSelector = proxySelector;
                  }
                ];
              }
            ];
          }
        ) routeSet;
      routes = routeObjects publishedRoutes;
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
      ) (builtins.attrValues cluster.routes);
    in
    assert lib.assertMsg backendSelectorsValid "Gateway routes require a non-empty backendPodSelector";
    assert lib.assertMsg (lib.all (route: !route.backendTLS || route.backendHostname != null) (
      builtins.attrValues cluster.routes
    )) "TLS Gateway routes require backendHostname";
    assert lib.assertMsg originModeValid "Gateway ingress mode and trusted edge CIDRs disagree";
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
          (object "gateway.envoyproxy.io/v1alpha1" "EnvoyProxy" "household" namespace {
            provider = {
              type = "Kubernetes";
              kubernetes = {
                envoyDeployment = {
                  replicas = 1;
                  container.image = proxyImage;
                  pod.nodeSelector."kubernetes.io/hostname" = computeResources.instance;
                };
                envoyService = {
                  name = "household-origin";
                  type = "NodePort";
                  externalTrafficPolicy = "Local";
                  patch = {
                    type = "StrategicMerge";
                    value.spec.ports = [
                      {
                        name = "https";
                        port = 443;
                        targetPort = 8443;
                        nodePort = cluster.ingress.nodePort;
                      }
                    ];
                  };
                };
              };
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
                sinks = [ { file.path = "/dev/stdout"; } ];
              }
            ];
          })
          (object "gateway.networking.k8s.io/v1" "Gateway" "household" namespace {
            gatewayClassName = "envoy";
            infrastructure.parametersRef = {
              group = "gateway.envoyproxy.io";
              kind = "EnvoyProxy";
              name = "household";
            };
            listeners = [
              {
                name = "https";
                protocol = "HTTPS";
                port = 443;
                allowedRoutes.namespaces.from = "Same";
                tls = {
                  mode = "Terminate";
                  certificateRefs = [
                    {
                      group = "";
                      kind = "Secret";
                      name = "gateway-tls";
                    }
                  ];
                };
              }
            ];
          })
          (object "gateway.envoyproxy.io/v1alpha1" "ClientTrafficPolicy" "trusted-edges" namespace {
            targetRefs = gatewayTarget;
            clientIPDetection =
              if cluster.ingress.mode == "direct" then
                { directSourceIP = { }; }
              else
                {
                  xForwardedFor.trustedCIDRs = peers;
                };
            requestID = if cluster.ingress.mode == "trustedEdges" then "PreserveOrGenerate" else "Generate";
          })
        ]
        # An empty proxy allowlist selects direct-source mode. Omit the ingress
        # policy instead of rendering a policy that denies every NodePort client.
        ++ lib.optional (peers != [ ]) (
          object "networking.k8s.io/v1" "NetworkPolicy" "private-origin" namespace {
            podSelector = proxySelector;
            policyTypes = [ "Ingress" ];
            ingress = [
              {
                from = map (cidr: { ipBlock = { inherit cidr; }; }) peers;
                ports = [
                  {
                    protocol = "TCP";
                    port = 8443;
                  }
                ];
              }
            ];
          }
        )
        ++ routes
        ++ backendGrants
        ++ backendTLS
        ++ backendIsolation;
      };
    };
}
