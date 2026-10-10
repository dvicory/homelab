{ config, inputs, lib, self, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      # Container contents execute as x86_64-linux, never from host/store binds.
      # Non-target frontends explicitly materialize them with a Linux builder;
      # amd64 emulation is reported and is not native ARM evidence.
      linuxPkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
      fixtureArgs = { inherit pkgs linuxPkgs lib config inputs self; };
      fixtures = {
        argo = import ./_kubernetes-api/argo/fixtures.nix fixtureArgs;
        secret = import ./_kubernetes-api/secret/fixtures.nix fixtureArgs;
        gateway = import ./_kubernetes-api/gateway/fixtures.nix fixtureArgs;
      };
      # Explicit opt-in settings use this system's host helpers while their
      # container contents retain the declared Linux execution architecture.
      fixtureList = builtins.attrValues fixtures;
      python = pkgs.python3.withPackages (p: [ p.pyyaml ]);
      nativePkgs = inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      nativeKubectl = if pkgs.stdenv.hostPlatform.isLinux then
        nativePkgs.k3s_1_35.k3sBundle
      else nativePkgs.kubectl.override {
        # K3s' multicall bundle is Linux-only. Reuse the native Unix kubectl
        # recipe with a verified source pin from the supported server minor.
        kubernetes = nativePkgs.kubernetes.overrideAttrs (_: {
          version = "1.35.0";
          src = nativePkgs.fetchFromGitHub {
            owner = "kubernetes";
            repo = "kubernetes";
            tag = "v1.35.0";
            hash = "sha256-AT1/4RhnVK/mAoNVqPIfSwbzD8VNRqKumOpE0fidJ74=";
          };
        });
      };
      imageReference = image: image.imageReference or "${image.imageName}:${image.imageTag}";
      helperPaths = lib.concatMap (fixture: fixture.settings.paths or [ ]) fixtureList;
      settings = assert lib.assertMsg (lib.versions.majorMinor nativeKubectl.version == "1.35")
        "The native Kubernetes fixture requires a host kubectl from the pinned K3s 1.35 minor.";
        pkgs.writeText "kubernetes-api-fixture.json" (
        builtins.toJSON ({
          docker = lib.getExe' pkgs.docker-client "docker";
          chainsaw = lib.getExe' pkgs.kyverno-chainsaw "chainsaw";
          kubectl = lib.getExe' nativeKubectl "kubectl";
          kubectlVersion = nativeKubectl.version;
          path = lib.makeBinPath ([ nativeKubectl pkgs.git pkgs.curl pkgs.jq pkgs.openssl pkgs.coreutils pkgs.docker-client pkgs.kyverno-chainsaw ] ++ helperPaths);
          image = "rancher/k3s:v1.35.8-k3s1@sha256:59fe491fd3b73204e499e40b325240d85c42c7189c3ae50150d37b78243f3b32";
          crd = ../../generated/manifests/prod-home/gateway-crds/CustomResourceDefinition-gateways-gateway-networking-k8s-io.yaml;
          scenarios = ./_kubernetes-api;
          requiredScenarios = [ "gateway-cel-admission" ] ++ lib.concatMap (fixture: fixture.scenarios) fixtureList;
          testDirectories = [ ./_kubernetes-api/gateway-cel-admission ] ++
            lib.concatMap (family: fixtures.${family}.testDirectories or [ (./_kubernetes-api + "/${family}") ]) [ "argo" "secret" "gateway" ];
          images = map (image: { archive = image; reference = imageReference image; })
            (lib.concatMap (fixture: fixture.images) fixtureList);
          kubernetesImages = lib.unique (lib.concatMap (fixture: fixture.kubernetesImages or [ ]) fixtureList);
          containers = lib.concatMap (fixture: fixture.containers or [ ]) fixtureList;
          registryImages = lib.unique (lib.concatMap (fixture: fixture.settings.registryImages or [ ]) fixtureList);
          registryManifestDirectories = lib.concatMap (fixture: fixture.settings.registryManifestDirectories or [ ]) fixtureList;
          setup = lib.mapAttrs (_: fixture: fixture.setup) fixtures;
        } // lib.mapAttrs (_: fixture: fixture.settings) fixtures)
      );
      # Only the required Linux wrapper carries the complete fixture closure.
      # Other package jobs build a portable CLI with an explicit input boundary.
      defaultFixture = lib.optionalString (pkgs.stdenv.hostPlatform.system == "x86_64-linux")
        "--fixture-settings ${settings}";
      runner = pkgs.writeShellScriptBin "verify-kubernetes-api" ''
        exec ${python}/bin/python3 ${./_kubernetes-api}/run.py ${defaultFixture} "$@"
      '';
    in
    {
      apps.verify-kubernetes-api = {
        type = "app";
        program = lib.getExe runner;
      };
      packages = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
        verify-kubernetes-api-fixture = settings;
      } // { verify-kubernetes-api = runner; };
      legacyPackages.verify-kubernetes-api-fixture = settings;
    };
}
