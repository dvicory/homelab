{ ... }:
{
  den.aspects.kubernetes.services.gateway.compute-resources.runtimeSecrets = {
    "gateway--gateway-tls--tls.crt" = {
      namespace = "gateway";
      name = "gateway-tls";
      key = "tls.crt";
      type = "kubernetes.io/tls";
    };
    "gateway--gateway-tls--tls.key" = {
      namespace = "gateway";
      name = "gateway-tls";
      key = "tls.key";
      type = "kubernetes.io/tls";
    };
    "gateway--gateway-tls--ca.crt" = {
      namespace = "gateway";
      name = "gateway-tls";
      key = "ca.crt";
      type = "kubernetes.io/tls";
    };
  };
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
      defaultTimeouts = {
        request = "15s";
        backendRequest = "15s";
      };
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
      routes = lib.mapAttrsToList (
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
      ) cluster.routes;
      backendGrants = lib.mapAttrsToList (
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
      ) cluster.routes;
      backendTLS = lib.mapAttrsToList (
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
            hostname = builtins.head route.hostnames;
            # Backend certificates must chain to a trusted public CA.
            wellKnownCACertificates = "System";
          };
        }
      ) (lib.filterAttrs (_: r: r.backendTLS) cluster.routes);
      backendSelectorsValid = lib.all (
        route: route ? backendPodSelector && route.backendPodSelector != { }
      ) (builtins.attrValues cluster.routes);
      backendIsolation = lib.mapAttrsToList (
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
      ) cluster.routes;
    in
    assert lib.assertMsg backendSelectorsValid "Gateway routes require a non-empty backendPodSelector";
    assert lib.assertMsg originModeValid "Gateway ingress mode and trusted edge CIDRs disagree";
    {
      applications.gateway-retained = {
        inherit namespace;
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
      applications.gateway = {
        inherit namespace;
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
