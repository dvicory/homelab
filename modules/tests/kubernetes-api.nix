{
  config,
  inputs,
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    let
      # Container contents execute as x86_64-linux, never from host/store binds.
      # Non-target frontends explicitly materialize them with a Linux builder;
      # amd64 emulation is reported and is not native ARM evidence.
      linuxPkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
      configurations = import ./_compute-configurations.nix {
        inherit self lib;
        system = linuxPkgs.stdenv.hostPlatform.system;
        hostName = config.den.clusters.prod-home.hostName;
      };
      k3sPackage = configurations.guest.config.services.k3s.package;
      kubernetesVersion = lib.head (lib.splitString "+" k3sPackage.version);
      # Exercise the selected Nix runtime, not an independently pinned registry
      # server that drifts away from the production Secret reconciler's client.
      serverImage = linuxPkgs.dockerTools.buildLayeredImage {
        name = "homelab/native-kubernetes-api";
        tag = lib.replaceStrings [ "+" ] [ "-" ] k3sPackage.version;
        contents = [
          k3sPackage
          linuxPkgs.busybox
          linuxPkgs.cacert
          linuxPkgs.dockerTools.fakeNss
        ];
        extraCommands = ''
          mkdir -p tmp run var/lib/rancher/k3s/agent/images
          chmod 1777 tmp
          ln -s ${k3sPackage.airgap-images} var/lib/rancher/k3s/agent/images/k3s-airgap-images.tar.zst
        '';
        config = {
          Entrypoint = [ "${k3sPackage}/bin/k3s" ];
          Env = [
            "PATH=/bin"
            "SSL_CERT_FILE=${linuxPkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "CRI_CONFIG_FILE=/var/lib/rancher/k3s/agent/etc/crictl.yaml"
          ];
          Volumes = {
            "/var/lib/kubelet" = { };
            "/var/lib/rancher/k3s" = { };
            "/var/lib/cni" = { };
            "/var/log" = { };
          };
        };
      };
      fixtureArgs = {
        inherit
          pkgs
          linuxPkgs
          lib
          config
          inputs
          self
          ;
      };
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
      nativeKubectl =
        if pkgs.stdenv.hostPlatform.isLinux then
          nativePkgs.k3s.k3sBundle
        else
          nativePkgs.kubectl.override {
            # The Linux multicall bundle cannot execute on Darwin. Build its
            # exact upstream Kubernetes client with the existing native recipe.
            kubernetes = nativePkgs.kubernetes.overrideAttrs (_: {
              version = kubernetesVersion;
              src = nativePkgs.fetchFromGitHub {
                owner = "kubernetes";
                repo = "kubernetes";
                tag = "v${kubernetesVersion}";
                hash = "sha256-M5wVu5678Eow6xMLNZXcfPLlS9z11RpwwzvmYd8NEeE=";
              };
            });
          };
      imageReference = image: image.imageReference or "${image.imageName}:${image.imageTag}";
      reporter = pkgs.replaceVars ./_kubernetes-api/report.py {
        expectedImage = imageReference serverImage;
        expectedServerVersion = "v${k3sPackage.version}";
      };
      apiHelpers = pkgs.linkFarm "kubernetes-api-helpers" [
        {
          name = "report.py";
          path = reporter;
        }
        {
          name = "run.py";
          path = ./_kubernetes-api/run.py;
        }
      ];
      helperPaths = lib.concatMap (fixture: fixture.settings.paths or [ ]) fixtureList;
      settings =
        assert lib.assertMsg (
          lib.versions.majorMinor nativeKubectl.version == lib.versions.majorMinor k3sPackage.version
        ) "The native Kubernetes fixture requires a host kubectl from the selected K3s minor.";
        pkgs.writeText "kubernetes-api-fixture.json" (
          builtins.toJSON (
            {
              docker = lib.getExe' pkgs.docker-client "docker";
              chainsaw = lib.getExe' pkgs.kyverno-chainsaw "chainsaw";
              kubectl = lib.getExe' nativeKubectl "kubectl";
              kubectlVersion = nativeKubectl.version;
              path = lib.makeBinPath (
                [
                  nativeKubectl
                  pkgs.git
                  pkgs.curl
                  pkgs.jq
                  pkgs.openssl
                  pkgs.coreutils
                  pkgs.docker-client
                  pkgs.kyverno-chainsaw
                ]
                ++ helperPaths
              );
              image = imageReference serverImage;
              imageArchive = serverImage;
              serverVersion = "v${k3sPackage.version}";
              crd = ../../generated/manifests/prod-home/gateway-crds/CustomResourceDefinition-gateways-gateway-networking-k8s-io.yaml;
              networkPolicy = ../../generated/manifests/prod-home/network-policy;
              scenarios = ./_kubernetes-api;
              requiredScenarios = [
                "gateway-cel-admission"
              ]
              ++ lib.concatMap (fixture: fixture.scenarios) fixtureList;
              testDirectories = [
                ./_kubernetes-api/gateway-cel-admission
              ]
              ++
                lib.concatMap (family: fixtures.${family}.testDirectories or [ (./_kubernetes-api + "/${family}") ])
                  [
                    "argo"
                    "secret"
                    "gateway"
                  ];
              images = map (image: {
                archive = image;
                reference = imageReference image;
              }) (lib.concatMap (fixture: fixture.images) fixtureList);
              kubernetesImages = lib.unique (
                lib.concatMap (fixture: fixture.kubernetesImages or [ ]) fixtureList
              );
              containers = lib.concatMap (fixture: fixture.containers or [ ]) fixtureList;
              registryImages = lib.unique (
                lib.concatMap (fixture: fixture.settings.registryImages or [ ]) fixtureList
              );
              registryManifestDirectories = [
                ../../generated/manifests/prod-home/network-policy
              ]
              ++ lib.concatMap (fixture: fixture.settings.registryManifestDirectories or [ ]) fixtureList;
              setup = lib.mapAttrs (_: fixture: fixture.setup) fixtures;
            }
            // lib.mapAttrs (_: fixture: fixture.settings) fixtures
          )
        );
      # Only the required Linux wrapper carries the complete fixture closure.
      # Other package jobs build a portable CLI with an explicit input boundary.
      defaultFixture = lib.optionalString (
        pkgs.stdenv.hostPlatform.system == "x86_64-linux"
      ) "--fixture-settings ${settings}";
      runner = pkgs.writeShellScriptBin "verify-kubernetes-api" ''
        if [ "''${1-}" = "--check-report" ]; then
          shift
          exec ${python}/bin/python3 ${reporter} --check-full "$@"
        fi
        export PYTHONPATH=${apiHelpers}
        exec ${python}/bin/python3 -P -m run ${defaultFixture} "$@"
      '';
    in
    {
      checks.verification-reports = pkgs.runCommand "verification-reports" { } ''
        export PYTHONDONTWRITEBYTECODE=1
        export PYTHONPATH=${apiHelpers}
        ${python}/bin/python3 ${reporter}
        ${python}/bin/python3 -P -c 'import run; run.self_check()'
        ${python}/bin/python3 ${../../.github/required-ci.py} --self-test
        touch "$out"
      '';
      apps.verify-kubernetes-api = {
        type = "app";
        program = lib.getExe runner;
      };
      packages =
        lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          verify-kubernetes-api-fixture = settings;
        }
        // {
          verify-kubernetes-api = runner;
        };
      legacyPackages.verify-kubernetes-api-fixture = settings;
    };
}
