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
    bareRoute = "jellyfin";
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
      jellyfin = routes.jellyfin // {
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
