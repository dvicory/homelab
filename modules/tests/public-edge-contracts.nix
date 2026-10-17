{ config, lib, ... }:
let
  cluster = config.den.clusters."prod-home";
  environment = config.den.environments.${cluster.environment};
  routes = cluster.routes;
  peerCIDRs = [
    "10.0.0.11/32"
    "10.0.0.12/32"
  ];
  testCluster = lib.recursiveUpdate cluster {
    ingress = {
      mode = "trustedEdges";
      trustedProxyCIDRs = peerCIDRs;
    };
    settings.kubernetes.services.identity.phase = "normal";
    settings.kubernetes.services.seerr.phase = "ready";
  };
  sourceFor =
    inventory:
    import ../den/aspects/services/public-edge.nix {
      config = {
        den = {
          clusters."prod-home" = inventory;
          environments.${inventory.environment} = environment;
        };
      };
      inherit lib;
    };
  edge = sourceFor testCluster;
  gateway =
    (import ../den/aspects/kubernetes/services/gateway.nix { }).den.aspects.kubernetes.services.gateway;
  remoteAspect = edge.den.aspects.services.remote-edge;
  homeAspect = edge.den.aspects.services.home-edge;
  tls = {
    primary = {
      certificate = "/run/edge/primary.crt";
      key = "/run/edge/primary.key";
    };
    backup = {
      certificate = "/run/edge/backup.crt";
      key = "/run/edge/backup.key";
    };
    identity = {
      certificate = "/run/edge/identity.crt";
      key = "/run/edge/identity.key";
    };
  };
  baseSettings = {
    enable = true;
    originHost = "10.0.0.10";
    originPort = 30443;
    originServerName = "origin.internal";
    originCA = "/run/edge/origin-ca.crt";
    bareRoute = "argocd";
    inherit tls;
  };
  remoteSettings = baseSettings // {
    peerAddress = "10.0.0.11";
  };
  homeSettings = baseSettings // {
    peerAddress = "10.0.0.12";
  };
  mkHost = name: settings: {
    settings = {
      services = {
        ${name} = settings;
      };
    };
  };
  unwrap = module: if module ? content then module.content else module;
  roleModule = aspect: host: unwrap (aspect.nixos { inherit host; });
  remoteModule = roleModule remoteAspect (mkHost "remote-edge" remoteSettings);
  homeModule = roleModule homeAspect (mkHost "home-edge" homeSettings);
  initialCluster = lib.recursiveUpdate testCluster {
    settings.kubernetes.services.identity.phase = "initial";
    settings.kubernetes.services.seerr.phase = "initial";
  };
  initialEdge = sourceFor initialCluster;
  initialRemoteModule = roleModule initialEdge.den.aspects.services.remote-edge (
    mkHost "remote-edge" remoteSettings
  );
  initialHomeModule = roleModule initialEdge.den.aspects.services.home-edge (
    mkHost "home-edge" homeSettings
  );
  provisioningCluster = lib.recursiveUpdate testCluster {
    settings.kubernetes.services.identity.phase = "provisioning";
    settings.kubernetes.services.seerr.phase = "initial";
  };
  provisioningEdge = sourceFor provisioningCluster;
  provisioningRemoteModule = roleModule provisioningEdge.den.aspects.services.remote-edge (
    mkHost "remote-edge" remoteSettings
  );
  provisioningHomeModule = roleModule provisioningEdge.den.aspects.services.home-edge (
    mkHost "home-edge" homeSettings
  );
  initialIdmHomeModule = roleModule initialEdge.den.aspects.services.home-edge (
    mkHost "home-edge" (homeSettings // { bareRoute = "idm"; })
  );
  provisioningIdmRemoteModule = roleModule provisioningEdge.den.aspects.services.remote-edge (
    mkHost "remote-edge" (remoteSettings // { bareRoute = "idm"; })
  );
  privatePhaseEdge =
    module:
    let
      virtualHosts = module.services.nginx.virtualHosts;
    in
    allAssertions module
    && builtins.attrNames virtualHosts == [ "_" ]
    && virtualHosts."_".default
    && virtualHosts."_".rejectSSL
    && virtualHosts."_".locations."/".return == "404";
  invalidBareRouteModule = roleModule initialEdge.den.aspects.services.remote-edge (
    mkHost "remote-edge" (remoteSettings // { bareRoute = "not-in-inventory"; })
  );
  publicRoutes = lib.filterAttrs (_: route: route.exposure == "public") routes;
  routeHosts =
    variant:
    lib.mapAttrsToList (
      name: route: builtins.elemAt route.hostnames (if name == "idm" then 0 else variant)
    ) publicRoutes;
  sorted = values: lib.sort builtins.lessThan values;
  allAssertions = module: lib.all (assertion: assertion.assertion) module.assertions;
  gatewayObjects =
    inventory:
    gateway.k8s-manifests {
      cluster = inventory;
      computeResources.instance = "compute-1";
      charts = { };
      inherit lib;
    };
  renderedGateway = gatewayObjects testCluster;
  allGatewayObjects =
    inventory:
    let
      rendered = gatewayObjects inventory;
      gated = rendered.applications.identity-gateway;
    in
    rendered.applications.gateway.objects ++ lib.optionals gated.condition gated.content.objects;
  gatewayRoutes = lib.filter (object: object.kind == "HTTPRoute") (allGatewayObjects testCluster);
  gatewayPolicy =
    inventory:
    builtins.head (
      lib.filter (
        object: object.kind == "ClientTrafficPolicy" && object.metadata.name == "trusted-edges"
      ) (allGatewayObjects inventory)
    );
  trustedGatewayPolicy = gatewayPolicy testCluster;
  directCluster = testCluster // {
    ingress = testCluster.ingress // {
      mode = "direct";
      trustedProxyCIDRs = [ ];
    };
  };
  directGatewayPolicy = gatewayPolicy directCluster;
  renderedPolicyFor = builtins.toJSON {
    trusted = trustedGatewayPolicy.spec;
    direct = directGatewayPolicy.spec;
  };
  clientTrafficPolicyCrd = ../../generated/manifests/prod-home/gateway-crds/CustomResourceDefinition-clienttrafficpolicies-gateway-envoyproxy-io.yaml;
  gatewayIdentityContract = lib.all (
    route:
    let
      filter = builtins.head (builtins.head route.spec.rules).filters;
    in
    filter.type == "RequestHeaderModifier"
    &&
      sorted filter.requestHeaderModifier.remove == sorted [
        "X-Real-IP"
        "X-Forwarded-User"
        "X-Forwarded-Email"
        "X-Auth-Request-User"
        "X-Auth-Request-Email"
        "Remote-User"
        "Forwarded"
      ]
  ) gatewayRoutes;
  seerrInitialCluster = lib.recursiveUpdate testCluster {
    settings.kubernetes.services.seerr.phase = "initial";
  };
  seerrInitialEdge = sourceFor seerrInitialCluster;
  seerrInitialRemote = roleModule seerrInitialEdge.den.aspects.services.remote-edge (
    mkHost "remote-edge" remoteSettings
  );
  seerrInitialHome = roleModule seerrInitialEdge.den.aspects.services.home-edge (
    mkHost "home-edge" homeSettings
  );
  hasRequests = objects: lib.any (object: object.metadata.name == "requests") objects;
  seerrPhaseContract =
    routes.requests.auth == "native"
    && routes.requests.exposure == "public"
    && !(hasRequests (allGatewayObjects seerrInitialCluster))
    && hasRequests (allGatewayObjects testCluster)
    &&
      lib.all
        (
          module:
          !(builtins.hasAttr (builtins.head routes.requests.hostnames) module.services.nginx.virtualHosts)
          && !(builtins.hasAttr (builtins.elemAt routes.requests.hostnames 1) module.services.nginx.virtualHosts)
        )
        [
          seerrInitialRemote
          seerrInitialHome
        ]
    && builtins.hasAttr (builtins.head routes.requests.hostnames) remoteModule.services.nginx.virtualHosts
    && builtins.hasAttr (builtins.elemAt routes.requests.hostnames 1) homeModule.services.nginx.virtualHosts;
  initialGatewayObjects = allGatewayObjects initialCluster;
  initialAdminPublicationAbsent = lib.all (
    object:
    !(builtins.elem object.kind [
      "HTTPRoute"
      "ReferenceGrant"
      "BackendTLSPolicy"
      "NetworkPolicy"
    ])
    || !(lib.hasInfix "argocd" object.metadata.name)
  ) initialGatewayObjects;
  gatewayRenderSucceeds =
    inventory: (builtins.tryEval (builtins.length (allGatewayObjects inventory))).success;
  timeoutContract = lib.all (
    route:
    (builtins.head route.spec.rules).timeouts == (
      if route.metadata.name == "jellyfin" then
        {
          request = "0s";
          backendRequest = "0s";
        }
      else
        {
          request = "15s";
          backendRequest = "15s";
        }
    )
  ) gatewayRoutes;
  backendTLSContract = lib.all (
    object:
    object.kind != "BackendTLSPolicy"
    || (
      object.spec.validation.hostname == routes.${object.metadata.name}.backendHostname
      && object.spec.validation.wellKnownCACertificates == "System"
    )
  ) (allGatewayObjects testCluster);
  nginxLogConfig = remoteModule.services.nginx.commonHttpConfig;
  querylessNginxLogs =
    lib.hasInfix "\"path\":\"$uri\"" nginxLogConfig
    && lib.hasInfix "\"request_id\":\"$request_id\"" nginxLogConfig
    && !(lib.hasInfix "$request_uri" nginxLogConfig)
    && !(lib.hasInfix "$args" nginxLogConfig);
  backendPolicies =
    inventory:
    lib.filter (object: lib.hasSuffix "-backend-ingress" object.metadata.name) (
      allGatewayObjects inventory
    );
  policyFor =
    inventory: name:
    builtins.head (
      lib.filter (policy: policy.metadata.name == "gateway-${name}-backend-ingress") (
        backendPolicies inventory
      )
    );
  backendPolicyContract =
    inventory:
    let
      routeNames = builtins.attrNames (
        lib.filterAttrs (_: route: route.manageBackendIngress) inventory.routes
      );
      objects = backendPolicies inventory;
      proxySelector = {
        namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "gateway";
        podSelector.matchLabels = {
          "gateway.envoyproxy.io/owning-gateway-namespace" = "gateway";
          "gateway.envoyproxy.io/owning-gateway-name" = "household";
        };
      };
    in
    sorted (map (policy: policy.metadata.name) objects)
    == sorted (map (name: "gateway-${name}-backend-ingress") routeNames)
    && lib.all (
      name:
      let
        route = inventory.routes.${name};
        policy = policyFor inventory name;
      in
      policy.metadata.namespace == route.namespace
      && policy.spec.podSelector.matchLabels == route.backendPodSelector
      && policy.spec.policyTypes == [ "Ingress" ]
      &&
        policy.spec.ingress == lib.optional route.sameNamespaceIngress {
          from = [
            {
              namespaceSelector.matchLabels."kubernetes.io/metadata.name" = route.namespace;
            }
          ];
        }
        ++ [
          {
            from = [ proxySelector ];
          }
        ]
    ) routeNames
    # Both shapes are in use: a route that leaves its in-cluster clients to
    # the backend owner admits only the proxy.
    && lib.any (route: route.sameNamespaceIngress) (builtins.attrValues inventory.routes)
    && lib.any (route: !route.sameNamespaceIngress) (builtins.attrValues inventory.routes);
  sameNamespaceCluster = testCluster // {
    routes = routes // {
      jellyfin = routes.jellyfin // {
        namespace = routes.argocd.namespace;
      };
    };
  };
  sameNamespaceBackendPolicyContract =
    let
      argocd = policyFor sameNamespaceCluster "argocd";
      jellyfin = policyFor sameNamespaceCluster "jellyfin";
    in
    builtins.length (backendPolicies sameNamespaceCluster) == builtins.length (
      builtins.attrNames (lib.filterAttrs (_: route: route.manageBackendIngress) routes)
    )
    && argocd.metadata.namespace == jellyfin.metadata.namespace
    && argocd.metadata.name != jellyfin.metadata.name
    && argocd.spec.podSelector.matchLabels != jellyfin.spec.podSelector.matchLabels;
  emptySelectorCluster = testCluster // {
    routes = routes // {
      argocd = routes.argocd // {
        backendPodSelector = { };
      };
    };
  };
  missingSelectorCluster = testCluster // {
    routes = routes // {
      argocd = builtins.removeAttrs routes.argocd [ "backendPodSelector" ];
    };
  };
  proxyContract =
    {
      module,
      settings,
      variant,
      domain,
      tlsFamily,
    }:
    let
      virtualHosts = module.services.nginx.virtualHosts;
      hosts = routeHosts variant;
      expectedHosts = hosts ++ [
        "_"
        domain
      ];
      locations = map (hostname: virtualHosts.${hostname}.locations."/") hosts;
      tlsHosts = hosts ++ [
        domain
      ];
      tlsFor =
        hostname: if hostname == builtins.head routes.idm.hostnames then tls.identity else tlsFamily;
      target = builtins.elemAt routes.${settings.bareRoute}.hostnames (
        if settings.bareRoute == "idm" then 0 else variant
      );
    in
    module.services.nginx.enable
    && sorted (builtins.attrNames virtualHosts) == sorted expectedHosts
    && lib.all (
      location:
      location.proxyPass == "https://${settings.originHost}:${toString settings.originPort}"
      && lib.hasInfix "proxy_ssl_server_name on;" location.extraConfig
      && lib.hasInfix "proxy_ssl_name ${settings.originServerName};" location.extraConfig
      && lib.hasInfix "proxy_ssl_verify on;" location.extraConfig
      && lib.hasInfix "proxy_ssl_trusted_certificate ${settings.originCA};" location.extraConfig
      && !(lib.hasInfix "proxy_set_header X-Real-IP" location.extraConfig)
      && lib.hasInfix "proxy_set_header X-Forwarded-For $remote_addr;" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Forwarded-Host $host;" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Forwarded-Proto https;" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Forwarded-Port 443;" location.extraConfig
      && lib.hasInfix "proxy_set_header Forwarded \"\";" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Forwarded-User \"\";" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Forwarded-Email \"\";" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Auth-Request-User \"\";" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Auth-Request-Email \"\";" location.extraConfig
      && lib.hasInfix "proxy_set_header Remote-User \"\";" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Request-ID $request_id;" location.extraConfig
      && !(lib.hasInfix "$http_x_request_id" location.extraConfig)
    ) locations
    && lib.all (
      hostname:
      virtualHosts.${hostname}.sslCertificate == (tlsFor hostname).certificate
      && virtualHosts.${hostname}.sslCertificateKey == (tlsFor hostname).key
    ) tlsHosts
    && virtualHosts.${domain}.locations."/".return == "308 https://${target}$request_uri"
    && virtualHosts."_".default
    && virtualHosts."_".rejectSSL
    && virtualHosts."_".locations."/".return == "404";
  routeProxyBijection =
    proxyContract {
      module = remoteModule;
      settings = remoteSettings;
      variant = 0;
      domain = environment.domain;
      tlsFamily = tls.primary;
    }
    && proxyContract {
      module = homeModule;
      settings = homeSettings;
      variant = 1;
      domain = environment.backupDomain;
      tlsFamily = tls.backup;
    };
  rejectedEdge =
    module: !allAssertions module && builtins.attrNames module.services.nginx.virtualHosts == [ "_" ];
  identityTLSPairsRejected =
    lib.all
      (
        identity:
        lib.all rejectedEdge [
          (roleModule remoteAspect (
            mkHost "remote-edge" (
              remoteSettings
              // {
                tls = tls // {
                  inherit identity;
                };
              }
            )
          ))
          (roleModule homeAspect (
            mkHost "home-edge" (
              homeSettings
              // {
                tls = tls // {
                  inherit identity;
                };
              }
            )
          ))
        ]
      )
      [
        {
          certificate = null;
          key = null;
        }
        {
          certificate = tls.identity.certificate;
          key = null;
        }
        {
          certificate = null;
          key = tls.identity.key;
        }
        {
          certificate = "";
          key = tls.identity.key;
        }
        {
          certificate = tls.identity.certificate;
          key = "";
        }
      ];
  rejectedRoute =
    name: changes:
    let
      inventory = testCluster // {
        routes = routes // {
          ${name} = routes.${name} // changes;
        };
      };
      invalidEdge = sourceFor inventory;
    in
    lib.all rejectedEdge [
      (roleModule invalidEdge.den.aspects.services.remote-edge (mkHost "remote-edge" remoteSettings))
      (roleModule invalidEdge.den.aspects.services.home-edge (mkHost "home-edge" homeSettings))
    ];
  identityShapesRejected = lib.all (hostnames: rejectedRoute "idm" { inherit hostnames; }) [
    [ ]
    [ "" ]
    [
      "id.bzfx.net"
      "id.backup.test"
    ]
    [
      "id.bzfx.net"
      "id.bzfx.net"
    ]
  ];
  applicationShapesRejected = lib.all (hostnames: rejectedRoute "argocd" { inherit hostnames; }) [
    [ ]
    [ (builtins.head routes.argocd.hostnames) ]
    [
      ""
      (builtins.elemAt routes.argocd.hostnames 1)
    ]
    [
      (builtins.head routes.argocd.hostnames)
      (builtins.head routes.argocd.hostnames)
    ]
    (lib.reverseList routes.argocd.hostnames)
    [
      "argocd.other.test"
      (builtins.elemAt routes.argocd.hostnames 1)
    ]
  ];
  identityCollisionsRejected =
    lib.all
      (
        entry:
        lib.all
          (
            hostname:
            let
              collisionEdge = sourceFor (
                testCluster
                // {
                  routes = routes // {
                    idm = routes.idm // {
                      hostnames = [ hostname ];
                    };
                  };
                }
              );
            in
            rejectedEdge (
              roleModule collisionEdge.den.aspects.services.${entry.name} (mkHost entry.name entry.settings)
            )
          )
          [
            entry.domain
            (builtins.elemAt routes.argocd.hostnames entry.variant)
          ]
      )
      [
        {
          name = "remote-edge";
          settings = remoteSettings;
          domain = environment.domain;
          variant = 0;
        }
        {
          name = "home-edge";
          settings = homeSettings;
          domain = environment.backupDomain;
          variant = 1;
        }
      ];
  identityBareRouteContract =
    lib.all
      (
        entry:
        let
          module = roleModule entry.aspect (mkHost entry.name (entry.settings // { bareRoute = "idm"; }));
        in
        allAssertions module
        &&
          module.services.nginx.virtualHosts.${entry.domain}.locations."/".return
          == "308 https://${builtins.head routes.idm.hostnames}$request_uri"
      )
      [
        {
          aspect = remoteAspect;
          name = "remote-edge";
          settings = remoteSettings;
          domain = environment.domain;
        }
        {
          aspect = homeAspect;
          name = "home-edge";
          settings = homeSettings;
          domain = environment.backupDomain;
        }
      ];
  noIdentityTLS = tls // {
    identity = {
      certificate = null;
      key = null;
    };
  };
  gatedIdentityNeedsNoTLS =
    lib.all
      (
        phaseEdge:
        lib.all allAssertions [
          (roleModule phaseEdge.den.aspects.services.remote-edge (
            mkHost "remote-edge" (remoteSettings // { tls = noIdentityTLS; })
          ))
          (roleModule phaseEdge.den.aspects.services.home-edge (
            mkHost "home-edge" (homeSettings // { tls = noIdentityTLS; })
          ))
        ]
      )
      [
        initialEdge
        provisioningEdge
      ];
  privateIdentityEdge = sourceFor (
    testCluster
    // {
      routes = routes // {
        idm = routes.idm // {
          exposure = "private";
        };
      };
    }
  );
  privateIdentityUnpublished =
    lib.all
      (
        module:
        allAssertions module
        && !(builtins.hasAttr (builtins.head routes.idm.hostnames) module.services.nginx.virtualHosts)
      )
      [
        (roleModule privateIdentityEdge.den.aspects.services.remote-edge (
          mkHost "remote-edge" (remoteSettings // { tls = noIdentityTLS; })
        ))
        (roleModule privateIdentityEdge.den.aspects.services.home-edge (
          mkHost "home-edge" (homeSettings // { tls = noIdentityTLS; })
        ))
      ];
  homeWithoutPrimaryTLS = roleModule homeAspect (
    mkHost "home-edge" (
      homeSettings
      // {
        tls = tls // {
          primary = {
            certificate = null;
            key = null;
          };
        };
      }
    )
  );
  badOriginModule = roleModule remoteAspect (
    mkHost "remote-edge" (remoteSettings // { originHost = "198.51.100.10"; })
  );
  badPeerModule = roleModule remoteAspect (
    mkHost "remote-edge" (remoteSettings // { peerAddress = "10.0.0.99"; })
  );
  badModeCluster = testCluster // {
    ingress = testCluster.ingress // {
      mode = "direct";
    };
  };
  badTrustedModeCluster = testCluster // {
    ingress = testCluster.ingress // {
      trustedProxyCIDRs = [ ];
    };
  };
  badModeModule = roleModule ((sourceFor badModeCluster).den.aspects.services.remote-edge) (
    mkHost "remote-edge" remoteSettings
  );
  badTLSModule = roleModule remoteAspect (
    mkHost "remote-edge" (
      remoteSettings
      // {
        tls = tls // {
          primary = {
            certificate = "/run/edge/primary.crt";
            key = null;
          };
        };
      }
    )
  );
  badPathCluster = testCluster // {
    routes = routes // {
      argocd = routes.argocd // {
        pathPrefix = "/unsupported";
      };
    };
  };
  badPathModule = roleModule ((sourceFor badPathCluster).den.aspects.services.remote-edge) (
    mkHost "remote-edge" remoteSettings
  );
  badTrustedCluster = testCluster // {
    ingress = testCluster.ingress // {
      trustedProxyCIDRs = peerCIDRs ++ [ "198.51.100.10/32" ];
    };
  };
  badTrustedModule = roleModule ((sourceFor badTrustedCluster).den.aspects.services.remote-edge) (
    mkHost "remote-edge" remoteSettings
  );
  failures = lib.filterAttrs (_: value: !value) {
    route-proxy-bijection = routeProxyBijection;
    valid-origin-and-peer-configuration = allAssertions remoteModule && allAssertions homeModule;
    initial-private-edge-rejects-unmatched =
      privatePhaseEdge initialRemoteModule && privatePhaseEdge initialHomeModule;
    provisioning-private-edge-rejects-unmatched =
      privatePhaseEdge provisioningRemoteModule && privatePhaseEdge provisioningHomeModule;
    gated-identity-bare-route-rejects-unmatched =
      privatePhaseEdge initialIdmHomeModule && privatePhaseEdge provisioningIdmRemoteModule;
    invalid-bare-route-inventory-key-rejected = !allAssertions invalidBareRouteModule;
    initial-admin-gateway-publication-absent = initialAdminPublicationAbsent;
    seerr-native-auth-phase-boundary = seerrPhaseContract;
    public-origin-rejected = !allAssertions badOriginModule;
    undeclared-peer-rejected = !allAssertions badPeerModule;
    incomplete-tls-rejected = !allAssertions badTLSModule;
    invalid-identity-tls-fails-closed = identityTLSPairsRejected;
    malformed-identity-routes-fail-closed = identityShapesRejected;
    malformed-application-routes-fail-closed = applicationShapesRejected;
    identity-hostname-collisions-fail-closed = identityCollisionsRejected;
    unsupported-identity-prefix-rejected = rejectedRoute "idm" { pathPrefix = "/unsupported"; };
    identity-bare-domain-redirect = identityBareRouteContract;
    gated-identity-needs-no-certificate = gatedIdentityNeedsNoTLS;
    private-identity-unpublished = privateIdentityUnpublished;
    home-identity-independent-of-primary-tls = allAssertions homeWithoutPrimaryTLS;
    unsupported-prefix-rejected = !allAssertions badPathModule;
    direct-mode-edge-rejected = !allAssertions badModeModule;
    gateway-identity-boundary = gatewayIdentityContract;
    gateway-direct-with-peers-rejected = !gatewayRenderSucceeds badModeCluster;
    gateway-trusted-without-peers-rejected = !gatewayRenderSucceeds badTrustedModeCluster;
    bounded-route-timeouts = timeoutContract;
    backend-tls-hostname-and-trust = backendTLSContract;
    queryless-nginx-logs = querylessNginxLogs;
    non-private-trusted-peer-rejected = !allAssertions badTrustedModule;
    backend-policy-selectors = backendPolicyContract testCluster;
    same-namespace-backend-policies = sameNamespaceBackendPolicyContract;
    empty-backend-selector-rejected = !gatewayRenderSucceeds emptySelectorCluster;
    missing-backend-selector-rejected = !gatewayRenderSucceeds missingSelectorCluster;
  };
in
{
  perSystem =
    { pkgs, ... }:
    let
      renderedPolicy = pkgs.writeText "client-traffic-policy.json" renderedPolicyFor;
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.public-edge-contracts =
        assert lib.assertMsg (failures == { })
          "Public-edge contract checks failed: ${builtins.concatStringsSep ", " (builtins.attrNames failures)}";
        pkgs.runCommand "public-edge-contracts" { nativeBuildInputs = [ python ]; } ''
          # Every spec key we render must be declared by the shipped CRD's
          # schema, and headers.requestID must carry an enum member; a
          # misplaced field (e.g. spec.requestID) is pruned by the API server.
          python - ${clientTrafficPolicyCrd} ${renderedPolicy} <<'PY'
          import json
          import sys
          import yaml

          crd = yaml.safe_load(open(sys.argv[1]))
          version = next(v for v in crd["spec"]["versions"] if v["storage"])
          spec_props = version["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]
          rendered = json.load(open(sys.argv[2]))
          for mode, spec in rendered.items():
              for key in spec:
                  assert key in spec_props, (
                      f"spec.{key} ({mode}) is not declared by the ClientTrafficPolicy CRD"
                  )
              rid_schema = spec_props["headers"]["properties"].get("requestID")
              assert rid_schema is not None, "spec.headers.requestID is not in the CRD schema"
              assert spec["headers"]["requestID"] in rid_schema["enum"], (
                  f"spec.headers.requestID={spec['headers']['requestID']} not in CRD enum"
              )
          PY
          touch "$out"
        '';
    };
}
