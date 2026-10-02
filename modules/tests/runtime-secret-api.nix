{ config, lib, self, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      configurations = import ./_compute-configurations.nix {
        inherit self lib system;
        hostName = config.den.clusters.prod-home.hostName;
      };
      guest = configurations.guest.config;
      instance = (builtins.fromJSON configurations.hostConfig.environment.etc."homelab/compute.json".text).instance;
      deployedSystem = self.nixosConfigurations.${instance}.config.nixpkgs.hostPlatform.system;
      provenance = "nixosConfigurations.${instance}.config.systemd.services.kubernetes-runtime-secrets.script";
      service = guest.systemd.services.kubernetes-runtime-secrets;
      k3s = guest.services.k3s.package;
      # Use the same evaluated script and command search path as the host seam.
      # No substitutions: its absolute state, kubeconfig and store paths stay intact.
      reconcile = pkgs.writeShellScript "runtime-secret-api-reconcile" ''
        export PATH=${lib.makeBinPath service.path}
        ${service.script}
      '';
      settings = pkgs.writeText "runtime-secret-api-settings.json" (
        builtins.toJSON {
          script = reconcile;
          kubectl = "${k3s}/bin/k3s";
          system = guest.nixpkgs.hostPlatform.system;
          scriptSha256 = builtins.hashString "sha256" service.script;
          inherit provenance deployedSystem;
          nativePlatformOverride = system != deployedSystem;
          virtualizationProbe = lib.getExe' pkgs.systemd "systemd-detect-virt";
        }
      );
      scenario = pkgs.writeShellScriptBin "runtime-secret-api-scenario" ''
        exec ${pkgs.python3}/bin/python3 ${./_runtime-secret-api/scenario.py} ${settings} "$@"
      '';
      test = pkgs.testers.runNixOSTest {
        name = "runtime-secret-api";
        requiredFeatures.kvm = true;
        nodes.machine = {
          environment.systemPackages = [ scenario ];
          system.stateVersion = "26.05";
          virtualisation.memorySize = 2048;
          virtualisation.cores = 2;
          virtualisation.diskSize = 8192;
          services.k3s = {
            enable = true;
            role = "server";
            package = k3s;
            disable = [ "local-storage" "servicelb" "traefik" "metrics-server" ];
            images = [ k3s.airgap-images ];
          };
        };
        testScript = ''
          import json
          start_all()
          machine.wait_until_succeeds(
              "${k3s}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml --request-timeout=10s get --raw=/readyz",
              timeout=180,
          )
          status, output = machine.execute(
              "env HOMELAB_RUNTIME_SECRET_FIXTURE=runtime-secret-api "
              "${lib.getExe scenario} --fixture runtime-secret-api"
          )
          print(output)
          report = json.loads(output)
          assert status == 0 and report["status"] == "passed", "runtime-Secret API scenario failed"
          assert report["scenario"] == "runtime-secret-ssa-uid", "runtime-Secret scenario missing"
        '';
      };
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.runtime-secret-api = test;
      packages.runtime-secret-api-driver = test.driver;
    };
}
