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
  seerrPhaseContract =
    lib.all (
      module:
      !(builtins.hasAttr (builtins.head routes.requests.hostnames) module.services.nginx.virtualHosts)
      && !(builtins.hasAttr (builtins.elemAt routes.requests.hostnames 1) module.services.nginx.virtualHosts)
    ) [ seerrInitialRemote seerrInitialHome ]
    && builtins.hasAttr (builtins.head routes.requests.hostnames) remoteModule.services.nginx.virtualHosts
    && builtins.hasAttr (builtins.elemAt routes.requests.hostnames 1) homeModule.services.nginx.virtualHosts;
  gatewayRenderSucceeds =
    inventory:
    (builtins.tryEval (builtins.seq (gateway.k8s-manifests {
      cluster = inventory;
      computeResources.instance = "compute-1";
      charts = { };
      inherit lib;
    }) true)).success;
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
    seerr-native-auth-phase-boundary = seerrPhaseContract;
    public-origin-rejected = !allAssertions badOriginModule;
    undeclared-peer-rejected = !allAssertions badPeerModule;
    incomplete-tls-rejected = !allAssertions badTLSModule;
    missing-canonical-tls-rejected = !allAssertions missingCanonicalTLSModule;
    unsupported-prefix-rejected = !allAssertions badPathModule;
    direct-mode-edge-rejected = !allAssertions badModeModule;
    gateway-direct-with-peers-rejected = !gatewayRenderSucceeds badModeCluster;
    gateway-trusted-without-peers-rejected = !gatewayRenderSucceeds badTrustedModeCluster;
    non-private-trusted-peer-rejected = !allAssertions badTrustedModule;
    empty-backend-selector-rejected = !gatewayRenderSucceeds emptySelectorCluster;
    missing-backend-selector-rejected = !gatewayRenderSucceeds missingSelectorCluster;
  };
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks.public-edge-contracts =
        assert lib.assertMsg (failures == { })
          "Public-edge contract checks failed: ${builtins.concatStringsSep ", " (builtins.attrNames failures)}";
        pkgs.writeText "public-edge-contracts" "ok\n";
    };
}
