{
  config,
  inputs,
  lib,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      cluster = config.den.clusters.prod-home // {
        routes = config.flake.clusterRoutes.prod-home.routes;
      };
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      computeResources = config.flake.clusterResources.prod-home // {
        inherit (compute) instance;
      };
      oidcClients = config.flake.nixidyEnvs.${system}.prod-home.config.oidcClients;
      gateway =
        (import ../den/aspects/kubernetes/services/gateway.nix { }).den.aspects.kubernetes.services.gateway;
      identity =
        (import ../den/aspects/kubernetes/services/identity.nix {
          inherit config inputs lib;
        }).den.aspects.kubernetes.services.identity;
      homarr =
        (import ../den/aspects/kubernetes/services/homarr.nix { inherit lib; })
        .den.aspects.kubernetes.services.homarr;
      public = {
        nodePort = 30444;
        originAddress = "100.64.0.1";
        peerAddress = "100.64.0.2";
        peerIPv6Address = "fd7a:115c:a1e0::2";
      };
      ready = lib.recursiveUpdate cluster {
        ingress.public = public;
        settings.kubernetes.services = {
          identity.phase = "normal";
          homarr.phase = "ready";
          seerr.phase = "ready";
        };
      };
      private = ready // {
        ingress = ready.ingress // {
          public = null;
        };
      };
      renderGateway =
        inventory:
        gateway.k8s-manifests {
          cluster = inventory;
          routes = inventory.routes;
          charts = { };
          inherit computeResources lib;
        };
      renderIdentity =
        inventory:
        identity.k8s-manifests {
          cluster = inventory;
          routes = inventory.routes;
          config = { inherit oidcClients; };
          inherit computeResources lib;
        };
      homarrIngress =
        inventory:
        (homarr.k8s-manifests {
          cluster = inventory;
          routes = inventory.routes;
          config = { inherit oidcClients; };
          computeResources = compute;
          charts = { };
        }).applications.homarr.resources.networkPolicies.homarr-ingress.spec.ingress;
      applicationObjects =
        application:
        if application.condition or true then (application.content or application).objects or [ ] else [ ];
      objects = rendered: lib.concatMap applicationObjects (lib.attrValues rendered.applications);
      find =
        kind: name: resources:
        lib.findFirst (o: o.kind == kind && o.metadata.name == name) null resources;
      routesIn = resources: lib.filter (o: o.kind == "HTTPRoute") resources;
      routeNames = resources: map (o: o.metadata.name) (routesIn resources);
      parents = route: map (p: p.name) route.spec.parentRefs;
      sorted = lib.sort builtins.lessThan;
      privateObjects = objects (renderGateway private);
      publicObjects = objects (renderGateway ready);
      publicHTTPRoutes = lib.filter (r: lib.elem "household-public" (parents r)) (routesIn publicObjects);
      proxyLabels = name: {
        "gateway.envoyproxy.io/owning-gateway-namespace" = "gateway";
        "gateway.envoyproxy.io/owning-gateway-name" = name;
      };
      gatewayPeer = name: {
        namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "gateway";
        podSelector.matchLabels = proxyLabels name;
      };
      publicAdmitted =
        rules: lib.any (rule: lib.elem (gatewayPeer "household-public") (rule.from or [ ])) rules;
      genericIngress =
        resources: name: (find "NetworkPolicy" "gateway-${name}-backend-ingress" resources).spec.ingress;
      idmIngress =
        inventory:
        (find "NetworkPolicy" "kanidm-private" (objects (renderIdentity inventory))).spec.ingress;
      expectedNames =
        inventory:
        lib.attrNames (
          lib.filterAttrs (
            name: route:
            (route.auth != "admin" || inventory.settings.kubernetes.services.identity.phase == "normal")
            && (name != "requests" || inventory.settings.kubernetes.services.seerr.phase == "ready")
            && (
              name != "home"
              || (
                inventory.settings.kubernetes.services.identity.phase == "normal"
                && inventory.settings.kubernetes.services.homarr.phase == "ready"
              )
            )
          ) inventory.routes
        );
      expectedPublic =
        inventory:
        lib.filter (
          name:
          inventory.ingress.public != null
          && inventory.routes.${name}.exposure == "public"
          && (name != "idm" || inventory.settings.kubernetes.services.identity.phase == "normal")
        ) (expectedNames inventory);
      phaseCases = lib.cartesianProduct {
        identity = [
          "initial"
          "provisioning"
          "normal"
        ];
        homarr = [
          "initial"
          "ready"
        ];
        seerr = [
          "initial"
          "ready"
        ];
      };
      phaseContract = lib.all (
        phase:
        let
          inventory = lib.recursiveUpdate ready {
            settings.kubernetes.services = {
              identity.phase = phase.identity;
              homarr.phase = phase.homarr;
              seerr.phase = phase.seerr;
            };
          };
          resources = objects (renderGateway inventory);
          policyObjects = objects (renderIdentity inventory);
          admins = lib.attrNames (lib.filterAttrs (_: r: r.auth == "admin") inventory.routes);
        in
        sorted (routeNames resources) == expectedNames inventory
        &&
          sorted (
            map (r: r.metadata.name) (
              lib.filter (r: lib.elem "household-public" (parents r)) (routesIn resources)
            )
          ) == expectedPublic inventory
        && lib.all (
          name: (find "SecurityPolicy" "${name}-admin" policyObjects != null) == (phase.identity == "normal")
        ) admins
        &&
          publicAdmitted (homarrIngress inventory) == (
            phase.identity == "normal" && phase.homarr == "ready" && inventory.routes.home.exposure == "public"
          )
        && publicAdmitted (idmIngress inventory) == (phase.identity == "normal")
      ) phaseCases;
      allPrivate = ready // {
        routes = lib.mapAttrs (_: route: route // { exposure = "private"; }) ready.routes;
      };
      privateRouteObjects = objects (renderGateway allPrivate);
      privateIdm = ready // {
        routes = ready.routes // {
          idm = ready.routes.idm // {
            exposure = "private";
          };
        };
      };
      customRouteCluster = ready // {
        routes = ready.routes // {
          argocd = ready.routes.argocd // {
            hostnames = [
              "admin.example.test"
              "second.example.test"
              "third.example.test"
            ];
            pathPrefix = "/control";
          };
        };
      };
      customRoute = find "HTTPRoute" "argocd" (objects (renderGateway customRouteCluster));
      policyContract =
        name: gatewayName: resources:
        let
          policy = find "ClientTrafficPolicy" name resources;
          removed = map lib.toLower policy.spec.headers.earlyRequestHeaders.remove;
        in
        policy.spec.targetRefs == [
          {
            group = "gateway.networking.k8s.io";
            kind = "Gateway";
            name = gatewayName;
          }
        ]
        && policy.spec.clientIPDetection == { directSourceIP = { }; }
        && policy.spec.headers.requestID == "Generate"
        && policy.spec.headers.xForwardedClientCert.mode == "Sanitize"
        && lib.all (header: lib.elem header removed) [
          "forwarded"
          "x-forwarded-for"
          "x-forwarded-host"
          "x-forwarded-proto"
          "x-forwarded-port"
          "x-forwarded-server"
          "x-real-ip"
          "x-forwarded-user"
          "x-forwarded-email"
          "x-auth-request-user"
          "x-auth-request-email"
          "remote-user"
          "x-request-id"
          "x-correlation-id"
          "x-client-request-id"
          "x-envoy-external-address"
          "x-envoy-internal"
        ];
      proxyContract =
        name: port:
        let
          proxy = find "EnvoyProxy" name publicObjects;
          gatewayObject = find "Gateway" name publicObjects;
          service = proxy.spec.provider.kubernetes.envoyService;
          log = (builtins.head proxy.spec.telemetry.accessLog.settings).format.json;
        in
        service.name == "${name}-origin"
        && service.type == "NodePort"
        && service.externalTrafficPolicy == "Local"
        &&
          service.patch.value.spec.ports == [
            {
              name = "https";
              port = 443;
              nodePort = port;
            }
          ]
        && gatewayObject.spec.infrastructure.parametersRef.name == name
        && (builtins.head gatewayObject.spec.listeners).protocol == "HTTPS"
        && (builtins.head gatewayObject.spec.listeners).tls.mode == "Terminate"
        && log.client == "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%"
        && log.path == "%PATH(NQ)%"
        && log.request_id == "%REQ(X-REQUEST-ID)%";
      renderingSucceeds =
        inventory: (builtins.tryEval (builtins.seq (renderGateway inventory) true)).success;
      invalidPublic =
        changes:
        !renderingSucceeds (
          ready
          // {
            ingress = ready.ingress // {
              public = public // changes;
            };
          }
        );
      invalidAddresses = [
        ""
        "100.64.0"
        "100.64.0.256"
        "100.064.0.1"
        "100.64.0.2/32"
        "::1"
        "127.0.0.1"
        "169.254.0.1"
        "198.51.100.1"
        "100.63.255.255"
        "100.128.0.0"
        "10.77.0.1"
        "172.27.50.1"
        "192.168.1.1"
        "8.8.8.8"
      ];
      adminOwnership = lib.all (
        name:
        let
          route = find "HTTPRoute" name (
            applicationObjects (renderGateway ready).applications.identity-gateway
          );
          policy = find "SecurityPolicy" "${name}-admin" (
            applicationObjects (renderIdentity ready).applications.identity-gateway
          );
        in
        route != null
        && policy != null
        && route.metadata.annotations."argocd.argoproj.io/sync-wave" == "0"
        && policy.metadata.annotations."argocd.argoproj.io/sync-wave" == "-1"
        &&
          policy.spec.targetRefs == [
            {
              group = "gateway.networking.k8s.io";
              kind = "HTTPRoute";
              inherit name;
            }
          ]
        &&
          policy.spec.oidc.provider.issuer
          == "https://${builtins.head ready.routes.idm.hostnames}/oauth2/openid/${policy.spec.oidc.clientID}"
        && !policy.spec.oidc.forwardAccessToken
        && !policy.spec.oidc.passThroughAuthHeader
        && find "HTTPRoute" name (renderGateway ready).applications.gateway.objects == null
      ) (lib.attrNames (lib.filterAttrs (_: r: r.auth == "admin") ready.routes));
      declaredObjects = publicObjects ++ objects (renderIdentity ready);
      objectKeys = map (
        o:
        builtins.toJSON [
          o.apiVersion
          o.kind
          (o.metadata.namespace or "")
          o.metadata.name
        ]
      ) declaredObjects;
      failures = lib.filterAttrs (_: value: !value) {
        default-private-entry =
          cluster.ingress.public == null
          && sorted (routeNames (objects (renderGateway cluster))) == expectedNames cluster
          && sorted (routeNames privateObjects) == lib.attrNames ready.routes
          && lib.all (r: parents r == [ "household" ]) (routesIn privateObjects)
          && find "Gateway" "household-public" privateObjects == null
          && find "EnvoyProxy" "household-public" privateObjects == null
          && find "ClientTrafficPolicy" "public-origin" privateObjects == null
          && find "NetworkPolicy" "public-origin" privateObjects == null
          && !publicAdmitted (idmIngress private)
          && !publicAdmitted (homarrIngress private);
        one-route-owner-and-declaration =
          sorted (routeNames publicObjects) == lib.attrNames ready.routes
          && lib.length (routeNames publicObjects) == lib.length (lib.unique (routeNames publicObjects))
          && lib.all (
            r:
            let
              declared = ready.routes.${r.metadata.name};
              rule = builtins.head r.spec.rules;
            in
            r.spec.hostnames == declared.hostnames
            && (builtins.head rule.backendRefs).name == declared.service
            && (builtins.head rule.backendRefs).namespace == declared.namespace
            && (builtins.head rule.backendRefs).port == declared.port
            && (builtins.head rule.matches).path.value == declared.pathPrefix
            && parents r == ([ "household" ] ++ lib.optional (declared.exposure == "public") "household-public")
          ) (routesIn publicObjects);
        public-route-filter =
          sorted (map (r: r.metadata.name) publicHTTPRoutes) == expectedPublic ready
          && lib.all (r: parents r == [ "household" ]) (routesIn privateRouteObjects)
          && !publicAdmitted (idmIngress allPrivate)
          && !publicAdmitted (homarrIngress allPrivate);
        phase-and-bootstrap-boundaries = phaseContract;
        declared-hostnames-and-prefix =
          customRoute.spec.hostnames == customRouteCluster.routes.argocd.hostnames
          && (builtins.head (builtins.head customRoute.spec.rules).matches).path.value == "/control"
          &&
            parents customRoute == [
              "household"
              "household-public"
            ];
        distinct-data-planes =
          proxyContract "household" ready.ingress.nodePort
          && proxyContract "household-public" public.nodePort
          &&
            (find "Gateway" "household" publicObjects).spec.listeners
            == (find "Gateway" "household-public" publicObjects).spec.listeners;
        direct-private-and-required-public-metadata =
          policyContract "private-origin" "household" publicObjects
          && policyContract "public-origin" "household-public" publicObjects
          && !((find "ClientTrafficPolicy" "private-origin" publicObjects).spec ? proxyProtocol)
          &&
            (find "ClientTrafficPolicy" "public-origin" publicObjects).spec.proxyProtocol == {
              optional = false;
            }
          && find "ClientTrafficPolicy" "trusted-edges" publicObjects == null;
        exact-public-receiver-peer =
          (find "NetworkPolicy" "public-origin" publicObjects).spec == {
            podSelector.matchLabels = proxyLabels "household-public";
            policyTypes = [ "Ingress" ];
            ingress = [
              {
                from = [ { ipBlock.cidr = "${public.peerAddress}/32"; } ];
                ports = [
                  {
                    protocol = "TCP";
                    port = 10443;
                  }
                ];
              }
            ];
          };
        per-route-backend-admission = lib.all (
          name:
          let
            route = ready.routes.${name};
            rules = genericIngress publicObjects name;
            backendRule = lib.last rules;
          in
          backendRule.from == (
            [ (gatewayPeer "household") ]
            ++ lib.optional (route.exposure == "public") (gatewayPeer "household-public")
          )
          && !publicAdmitted (genericIngress privateRouteObjects name)
          &&
            (find "NetworkPolicy" "gateway-${name}-backend-ingress" publicObjects).spec.podSelector.matchLabels
            == route.backendPodSelector
        ) (lib.attrNames (lib.filterAttrs (_: r: r.manageBackendIngress) ready.routes));
        identity-special-admission =
          publicAdmitted (idmIngress privateIdm)
          && !lib.elem "household-public" (
            parents (find "HTTPRoute" "idm" (objects (renderGateway privateIdm)))
          )
          && lib.all (
            rule:
            !publicAdmitted [ rule ]
            ||
              rule.ports == [
                {
                  protocol = "TCP";
                  port = 8443;
                }
              ]
          ) (idmIngress ready)
          && find "NetworkPolicy" "gateway-idm-backend-ingress" publicObjects == null
          && find "NetworkPolicy" "gateway-home-backend-ingress" publicObjects == null;
        administrator-policy-owner-and-order = adminOwnership;
        unique-declared-object-ownership = lib.length objectKeys == lib.length (lib.unique objectKeys);
        unsafe-public-inputs-rejected =
          lib.all (
            address: invalidPublic { originAddress = address; } && invalidPublic { peerAddress = address; }
          ) invalidAddresses
          && invalidPublic { peerAddress = public.originAddress; }
          && lib.all (peerIPv6Address: invalidPublic { inherit peerIPv6Address; }) [
            ""
            "fd7a:115c:a1e0:::2"
            "fd7a:115c:a1e0:1:2:3:4"
            "fd7a:115c:a1e0:1:2:3:4:5:6"
            "fd7a:115c:a1e0::gg"
            "fd00::2"
            "::1"
            null
          ]
          && invalidPublic { nodePort = ready.ingress.nodePort; }
          && lib.all (nodePort: invalidPublic { inherit nodePort; }) [
            0
            29999
            32768
            65536
            (-1)
            "30444"
          ];
        unsafe-private-ports-rejected =
          lib.all
            (
              nodePort:
              !renderingSucceeds (
                private
                // {
                  ingress = private.ingress // {
                    inherit nodePort;
                  };
                }
              )
              && !renderingSucceeds (
                ready
                // {
                  ingress = ready.ingress // {
                    inherit nodePort;
                  };
                }
              )
            )
            [
              0
              65536
              (-1)
              "30443"
              null
              true
            ];
        valid-public-port-boundaries =
          lib.all
            (
              nodePort:
              renderingSucceeds (
                ready
                // {
                  ingress = ready.ingress // {
                    public = public // {
                      inherit nodePort;
                    };
                  };
                }
              )
            )
            [
              30000
              32767
            ];
        valid-tailnet-address-boundaries =
          lib.all
            (
              addresses:
              renderingSucceeds (
                ready
                // {
                  ingress = ready.ingress // {
                    public = public // addresses;
                  };
                }
              )
            )
            [
              {
                originAddress = "100.64.0.1";
                peerAddress = "100.127.255.254";
                peerIPv6Address = "fd7a:115c:a1e0:0:0:0:0:2";
              }
              {
                originAddress = "100.127.255.254";
                peerAddress = "100.64.0.1";
                peerIPv6Address = "fd7a:115c:a1e0::1";
              }
            ];
        missing-backend-selector-rejected =
          !renderingSucceeds (
            ready
            // {
              routes = ready.routes // {
                argocd = builtins.removeAttrs ready.routes.argocd [ "backendPodSelector" ];
              };
            }
          );
        empty-backend-selector-rejected =
          !renderingSucceeds (
            ready
            // {
              routes = ready.routes // {
                argocd = ready.routes.argocd // {
                  backendPodSelector = { };
                };
              };
            }
          );
        missing-backend-tls-hostname-rejected =
          !renderingSucceeds (
            ready
            // {
              routes = ready.routes // {
                idm = ready.routes.idm // {
                  backendHostname = null;
                };
              };
            }
          );
      };
    in
    {
      checks.public-edge-contracts =
        assert lib.assertMsg (
          failures == { }
        ) "Public-entry contract checks failed: ${lib.concatStringsSep ", " (lib.attrNames failures)}";
        pkgs.writeText "public-edge-contracts" "ok\n";
    };
}
