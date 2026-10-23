{
  config,
  inputs,
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        guest = self.nixosConfigurations.compute-1.config;
        nodeText = guest.environment.etc."homelab/retained-node.json".text;
        node = builtins.fromJSON (builtins.unsafeDiscardStringContext nodeText);
        root = node.root // {
          id = "fixture/root-v1";
          source = {
            fsType = "tmpfs";
            name = "retained-production-data";
            root = "/original";
          };
        };
        descriptor = node // {
          inherit root;
        };
        aspect = import ../den/aspects/services/retained-runtime.nix { inherit config inputs; };
        imageName = "homelab/retained-integration-proof:1";
        image = pkgs.dockerTools.buildImage {
          name = "homelab/retained-integration-proof";
          tag = "1";
          copyToRoot = pkgs.buildEnv {
            name = "retained-integration-image";
            paths = [ pkgs.busybox ];
            pathsToLink = [ "/bin" ];
          };
          config.Cmd = [
            "/bin/sleep"
            "3600"
          ];
        };
        test =
          (pkgs.testers.runNixOSTest {
            name = "retained-runtime-native";
            globalTimeout = 1500;
            requiredFeatures.kvm = true;
            nodes.machine = {
              imports = [ aspect.den.aspects.services.retained-runtime.nixos ];
              system.stateVersion = "26.05";
              networking.hostName = "compute-1";
              networking.firewall.enable = false;
              # Selected public controller/helper images are pulled by real K3s;
              # all resulting image/data writes stay in the disposable guest.
              virtualisation = {
                cores = 2;
                memorySize = 2560;
                diskSize = 4096;
                restrictNetwork = false;
              };
              environment.systemPackages = [
                pkgs.python3
                pkgs.coreutils
                pkgs.util-linux
                pkgs.systemd
              ];
              environment.etc."homelab/retained-node.json".text = lib.mkForce (
                builtins.appendContext (builtins.toJSON descriptor) (builtins.getContext nodeText)
              );
              environment.etc."retained-production-inputs.json".text = builtins.appendContext (builtins.toJSON {
                inherit imageName root;
                inherit (node) helper k3s;
                hook = guest.system.build.retainedRuntimeHook;
                nodeName = "compute-1";
                manifests = self.packages.${system}.prod-home-manifests;
              }) (builtins.getContext nodeText);
              services.k3s = {
                enable = true;
                role = "server";
                package = guest.services.k3s.package;
                images = [ image ];
                disable = [
                  "traefik"
                  "servicelb"
                  "metrics-server"
                  "local-storage"
                  "coredns"
                ];
                extraFlags = [
                  "--pause-image=${imageName}"
                  "--disable-network-policy"
                ];
              };
            };
            testScript = ''
              start_all()
              machine.wait_for_unit("k3s.service", timeout=180)
              status, output = machine.execute("timeout --signal=TERM --kill-after=10s 1300s ${pkgs.python3}/bin/python3 -u ${./retained-runtime-native.py}", timeout=1320)
              print(output)
              machine.copy_from_machine("/run/retained-production", "retained-runtime-evidence")
              assert status == 0, "native retained runtime integration failed"
            '';
          }).overrideTestDerivation
            (_: {
              # The selected immutable images are pulled through the real registry.
              # Match the existing online VM gates: sandbox = relaxed is required.
              __noChroot = true;
            });
      in
      {
        legacyPackages.retained-runtime-native-test = test;
        checks.retained-runtime-native = test // {
          meta = test.meta // {
            hestia.group = "${system}-retained-runtime-native";
          };
        };
      }
    );
}
