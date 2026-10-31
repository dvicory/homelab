{
  config,
  inputs,
  lib,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  compute =
    config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
  homarr =
    (import ../den/aspects/kubernetes/services/homarr.nix { inherit lib; })
    .den.aspects.kubernetes.services.homarr;
  gateway =
    (import ../den/aspects/kubernetes/services/gateway.nix { }).den.aspects.kubernetes.services.gateway;
  identity =
    (import ../den/aspects/kubernetes/services/identity.nix { inherit config inputs lib; })
    .den.aspects.kubernetes.services.identity;
  render =
    inventory:
    homarr.k8s-manifests {
      cluster = inventory;
      computeResources = compute;
      charts.bjw-s-labs.app-template = { };
    };
  variants = lib.cartesianProduct {
    identity = [
      "initial"
      "provisioning"
      "normal"
    ];
    homarr = [
      "initial"
      "ready"
    ];
  };
  phaseBoundary = lib.all (
    phase:
    let
      inventory = lib.recursiveUpdate cluster {
        settings.kubernetes.services.identity.phase = phase.identity;
        settings.kubernetes.services.homarr.phase = phase.homarr;
      };
      objects =
        (gateway.k8s-manifests {
          cluster = inventory;
          computeResources = compute;
          charts = { };
          inherit lib;
        }).applications.gateway.objects;
      published = lib.any (o: o.kind == "HTTPRoute" && o.metadata.name == "home") objects;
      ingress =
        (render inventory).applications.homarr.resources.networkPolicies.homarr-ingress.spec.ingress;
    in
    published == (phase.identity == "normal" && phase.homarr == "ready")
    && (
      if phase.homarr == "initial" then
        ingress == [ ]
      else
        ingress == [
          {
            from = [
              {
                namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "gateway";
                podSelector.matchLabels = {
                  "gateway.envoyproxy.io/owning-gateway-namespace" = "gateway";
                  "gateway.envoyproxy.io/owning-gateway-name" = "household";
                };
              }
            ];
            ports = [
              {
                protocol = "TCP";
                port = 7575;
              }
            ];
          }
        ]
    )
  ) variants;
  objects =
    (identity.k8s-manifests {
      inherit cluster lib;
      computeResources = compute;
    }).applications.identity.objects;
  provision =
    (lib.findFirst (o: o.kind == "ConfigMap" && o.metadata.name == "kanidm-provision") null objects)
    .data;
  state = builtins.fromJSON provision."state.json";
  clients = builtins.fromJSON provision."clients.json";
  client = lib.findFirst (c: c.name == "homarr") null clients;
  app = (render cluster).applications.homarr;
  container = app.helm.releases.homarr.values.controllers.main.containers.main;
  failures = lib.filterAttrs (_: value: !value) {
    private-onboarding-and-gateway-only-ingress = phaseBoundary;
    oidc-claims-and-redirect-boundary =
      client.scopes == lib.splitString " " container.env.AUTH_OIDC_SCOPE_OVERWRITE
      && builtins.elem "groups_name" client.scopes
      &&
        state.systems.oauth2.homarr.originUrl
        == map (host: "https://${host}/api/auth/callback/oidc") cluster.routes.home.hostnames
      && !state.systems.oauth2.homarr.allowInsecureClientDisablePkce
      && !state.systems.oauth2.homarr.public;
  };
in
{
  perSystem = { pkgs, ... }: {
    checks.homarr-contracts =
      assert lib.assertMsg (
        failures == { }
      ) "Homarr checks failed: ${lib.concatStringsSep ", " (builtins.attrNames failures)}";
      pkgs.writeText "homarr-contracts" "ok\n";
    checks.homarr-encryption-key = pkgs.runCommand "homarr-encryption-key" { } ''
      {
        ${(homarr.compute-resources { }).runtimeSecrets.portal--homarr--SECRET_ENCRYPTION_KEY.generator {
          inherit pkgs;
        }}
      } > key
      test "$(wc -c < key)" -eq 64
      LC_ALL=C grep -Eq '^[0-9a-fA-F]{64}$' key
      touch "$out"
    '';
  };
}
