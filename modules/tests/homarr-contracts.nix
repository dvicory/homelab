{
  config,
  lib,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      oidcApps = config.flake.nixidyEnvs.${system}.prod-home.config.oidcApps;
      cluster = config.den.clusters.prod-home;
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      homarr =
        (import ../den/aspects/kubernetes/services/homarr.nix { inherit lib; })
        .den.aspects.kubernetes.services.homarr;
      gateway =
        (import ../den/aspects/kubernetes/services/gateway.nix { }).den.aspects.kubernetes.services.gateway;
      render =
        inventory:
        homarr.k8s-manifests {
          cluster = inventory;
          config = { inherit oidcApps; };
          computeResources = compute;
          charts.bjw-s-labs.app-template = { };
        };
      phases = [
        "initial"
        "ready"
      ];
      phaseBoundary = lib.all (
        phase:
        let
          inventory = lib.recursiveUpdate cluster {
            settings.kubernetes.services.homarr.phase = phase;
          };
          ingress =
            (render inventory).applications.homarr.resources.networkPolicies.homarr-ingress.spec.ingress;
        in
        if phase == "initial" then
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
      ) phases;
      publicationBoundary =
        lib.all
          (
            phase:
            let
              inventory = lib.recursiveUpdate cluster {
                settings.kubernetes.services = {
                  identity.phase = phase.identity;
                  homarr.phase = phase.homarr;
                  # Policy renders pair these phases; exercise the opposite state here.
                  seerr.phase = if phase.homarr == "ready" then "initial" else "ready";
                };
              };
              objects =
                (gateway.k8s-manifests {
                  cluster = inventory;
                  computeResources = compute;
                  charts = { };
                  inherit lib;
                }).applications.gateway.objects;
            in
            builtins.length (lib.filter (o: o.kind == "HTTPRoute" && o.metadata.name == "home") objects)
            == (if phase.identity == "normal" && phase.homarr == "ready" then 1 else 0)
          )
          (
            lib.cartesianProduct {
              identity = [
                "initial"
                "provisioning"
                "normal"
              ];
              homarr = phases;
            }
          );
      failures = lib.filterAttrs (_: value: !value) {
        private-onboarding-and-gateway-only-ingress = phaseBoundary;
        publication-independent-of-seerr = publicationBoundary;
      };
    in
    {
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
