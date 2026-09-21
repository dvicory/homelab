{ config, lib, ... }:
let
  cluster = config.den.clusters."prod-home";
  environment = config.den.environments.${cluster.environment};
  routes = cluster.routes;
  peerCIDRs = [
    "10.0.0.11/32"
    "10.0.0.12/32"
  ];
  testCluster = cluster // {
    ingress = cluster.ingress // {
      trustedProxyCIDRs = peerCIDRs;
    };
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
  routeHosts =
    variant: map (route: builtins.elemAt route.hostnames variant) (builtins.attrValues routes);
  sorted = values: lib.sort builtins.lessThan values;
  allAssertions = module: lib.all (assertion: assertion.assertion) module.assertions;
  gatewayObjects =
    inventory:
    gateway.k8s-manifests {
      cluster = inventory;
      compute.instance = "compute-1";
      charts = { };
      inherit lib;
    };
  backendPolicies =
    inventory:
    lib.filter (object: lib.hasSuffix "-backend-ingress" object.metadata.name) (
      (gatewayObjects inventory).applications.gateway.objects
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
    builtins.length (backendPolicies sameNamespaceCluster) == 2
    && argocd.metadata.namespace == idm.metadata.namespace
    && argocd.metadata.name != idm.metadata.name
    && argocd.spec.podSelector.matchLabels != idm.spec.podSelector.matchLabels;
  gatewayRenderSucceeds =
    inventory: (builtins.tryEval ((gatewayObjects inventory).applications.gateway.objects)).success;
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
        "_"
        domain
      ];
      target = builtins.elemAt routes.${settings.bareRoute}.hostnames variant;
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
      && lib.hasInfix "proxy_set_header X-Forwarded-For $remote_addr;" location.extraConfig
      && lib.hasInfix "proxy_set_header Forwarded \"\";" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Forwarded-User \"\";" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Forwarded-Email \"\";" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Auth-Request-User \"\";" location.extraConfig
      && lib.hasInfix "proxy_set_header X-Auth-Request-Email \"\";" location.extraConfig
      && lib.hasInfix "proxy_set_header Remote-User \"\";" location.extraConfig
    ) locations
    && lib.all (
      hostname:
      virtualHosts.${hostname}.sslCertificate == tlsFamily.certificate
      && virtualHosts.${hostname}.sslCertificateKey == tlsFamily.key
    ) tlsHosts
    && virtualHosts.${domain}.locations."/".return == "308 https://${target}$request_uri"
    && virtualHosts."_".default
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
  badOriginModule = roleModule remoteAspect (
    mkHost "remote-edge" (remoteSettings // { originHost = "198.51.100.10"; })
  );
  badPeerModule = roleModule remoteAspect (
    mkHost "remote-edge" (remoteSettings // { peerAddress = "10.0.0.99"; })
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
      trustedProxyCIDRs = [ "198.51.100.10/32" ];
    };
  };
  badTrustedModule = roleModule ((sourceFor badTrustedCluster).den.aspects.services.remote-edge) (
    mkHost "remote-edge" remoteSettings
  );
  failures = lib.filterAttrs (_: value: !value) {
    route-proxy-bijection = routeProxyBijection;
    route-inventory-nonempty = routes != { };
    valid-origin-and-peer-configuration = allAssertions remoteModule && allAssertions homeModule;
    public-origin-rejected = !allAssertions badOriginModule;
    undeclared-peer-rejected = !allAssertions badPeerModule;
    incomplete-tls-rejected = !allAssertions badTLSModule;
    unsupported-prefix-rejected = !allAssertions badPathModule;
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
    {
      checks.public-edge-contracts =
        assert lib.assertMsg (failures == { })
          "Public-edge contract checks failed: ${builtins.concatStringsSep ", " (builtins.attrNames failures)}";
        pkgs.writeText "public-edge-contracts" "ok\n";
    };
}
