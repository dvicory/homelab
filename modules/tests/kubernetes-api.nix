{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      python = pkgs.python3.withPackages (p: [ p.pyyaml ]);
      settings = pkgs.writeText "kubernetes-api-fixture.json" (
        builtins.toJSON {
          docker = lib.getExe' pkgs.docker-client "docker";
          chainsaw = lib.getExe' pkgs.kyverno-chainsaw "chainsaw";
          image = "rancher/k3s:v1.35.8-k3s1@sha256:59fe491fd3b73204e499e40b325240d85c42c7189c3ae50150d37b78243f3b32";
          crd = ../../generated/manifests/prod-home/gateway-crds/CustomResourceDefinition-gateways-gateway-networking-k8s-io.yaml;
          scenarios = ./_kubernetes-api;
        }
      );
      runner = pkgs.writeShellScriptBin "verify-kubernetes-api" ''
        exec ${python}/bin/python3 ${./_kubernetes-api/run.py} ${settings} "$@"
      '';
    in
    {
      packages.verify-kubernetes-api = runner;
      apps.verify-kubernetes-api = {
        type = "app";
        program = lib.getExe runner;
      };
    };
}
