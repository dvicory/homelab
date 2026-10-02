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
    variant: map (route: builtins.elemAt route.hostnames variant) (builtins.attrValues publicRoutes);
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
    && lib.all (
      module:
      !(builtins.hasAttr (builtins.head routes.requests.hostnames) module.services.nginx.virtualHosts)
      && !(builtins.hasAttr (builtins.elemAt routes.requests.hostnames 1) module.services.nginx.virtualHosts)
    ) [ seerrInitialRemote seerrInitialHome ]
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
  envoyProxy = builtins.head (
    lib.filter (object: object.kind == "EnvoyProxy") renderedGateway.applications.gateway.objects
  );
  gatewayImage = "docker.io/envoyproxy/gateway:v1.9.1@sha256:0049bcb384c591c6a6dd043fe5c9929ef6e74f230e12dd678d2d3701df9b301e";
  proxyImage = "docker.io/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c13125d1629637cb4e4cce7207009fb7cc2c8027f9742758549d15b6f4";
  controllerValues =
    renderedGateway.applications.gateway-controller.helm.releases.envoy-gateway.values;
  pinnedImages =
    controllerValues.global.images.envoyGateway.image == gatewayImage
    && controllerValues.global.images.envoyProxy.image == proxyImage
    && controllerValues.config.envoyGateway.provider.kubernetes.shutdownManager.image == gatewayImage
    && envoyProxy.spec.provider.kubernetes.envoyDeployment.container.image == proxyImage;
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
      routeNames = builtins.attrNames inventory.routes;
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
        policy.spec.ingress == [
          {
            from = [
              {
                namespaceSelector.matchLabels."kubernetes.io/metadata.name" = route.namespace;
              }
            ];
          }
          {
            from = [ proxySelector ];
          }
        ]
    ) routeNames;
  sameNamespaceCluster = testCluster // {
    routes = routes // {
      idm = routes.idm // {
        namespace = routes.argocd.namespace;
      };
    };
  };
  sameNamespaceBackendPolicyContract =
    let
      argocd = policyFor sameNamespaceCluster "argocd";
      idm = policyFor sameNamespaceCluster "idm";
    in
    builtins.length (backendPolicies sameNamespaceCluster)
    == builtins.length (builtins.attrNames routes)
    && argocd.metadata.namespace == idm.metadata.namespace
    && argocd.metadata.name != idm.metadata.name
    && argocd.spec.podSelector.matchLabels != idm.spec.podSelector.matchLabels;
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
      canonicalHost ? null,
      canonicalTLS ? null,
    }:
    let
      virtualHosts = module.services.nginx.virtualHosts;
      hosts = routeHosts variant ++ lib.optional (canonicalHost != null) canonicalHost;
      expectedHosts = hosts ++ [
        "_"
        domain
      ];
      locations = map (hostname: virtualHosts.${hostname}.locations."/") hosts;
      tlsHosts = hosts ++ [
        domain
      ];
      tlsFor =
        hostname: if canonicalHost != null && hostname == canonicalHost then canonicalTLS else tlsFamily;
      target = builtins.elemAt routes.${settings.bareRoute}.hostnames variant;
    in
    module.services.nginx.enable
    && sorted (builtins.attrNames virtualHosts) == sorted expectedHosts
    && lib.all (
      location:
      location.proxyPass == "https://${settings.originHost}:${toString settings.originPort}"
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
      canonicalHost = builtins.head routes.idm.hostnames;
      canonicalTLS = tls.primary;
    };
  missingCanonicalTLSModule = roleModule homeAspect (
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
    route-inventory-nonempty = routes != { };
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
    missing-canonical-tls-rejected = !allAssertions missingCanonicalTLSModule;
    unsupported-prefix-rejected = !allAssertions badPathModule;
    direct-mode-edge-rejected = !allAssertions badModeModule;
    gateway-identity-boundary = gatewayIdentityContract;
    gateway-direct-with-peers-rejected = !gatewayRenderSucceeds badModeCluster;
    gateway-trusted-without-peers-rejected = !gatewayRenderSucceeds badTrustedModeCluster;
    bounded-route-timeouts = timeoutContract;
    backend-tls-hostname-and-trust = backendTLSContract;
    envoy-images-pinned = pinnedImages;
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
