{ lib, self, ... }:
{
  perSystem = { pkgs, system, ... }: lib.optionalAttrs (system == "x86_64-linux") (
    let
      imageA = self.packages.${system}.retained-directories-image;
      # Test-only genuine Go compilation adds an observable CLI capability.
      # Existing retained safety logic and its package tests remain unchanged.
      runtimeB = self.packages.${system}.compute-runtime.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace cmd/retained-directories/main.go --replace-fail 'func main() {' 'func main() {
            if len(os.Args) == 2 && os.Args[1] == "--version" {
              fmt.Println("fixture-v2")
              return
            }'
        '';
      });
      imageB = pkgs.callPackage ../../pkgs/by-name/retained-directories-image/package.nix {
        compute-runtime = runtimeB;
      };
      # Reference flakes point at the exact real, prebuilt producer derivations.
      # Git commits in the VM provide genuine immutable source SHA/run receipts.
      sourceFor = image: pkgs.writeTextDir "flake.nix" ''
        {
          outputs = { self }: {
            packages.${system}.retained-directories-image = {
              type = "derivation";
              name = ${builtins.toJSON image.name};
              outPath = ${builtins.toJSON (toString image)};
              drvPath = ${builtins.toJSON image.drvPath};
              outputName = "out";
              outputs = [ "out" ];
            };
          };
        }
      '';
      sourceA = sourceFor imageA;
      sourceB = sourceFor imageB;
      tool = self.packages.${system}.helper-release;
      k3s = self.nixosConfigurations.compute-1.config.services.k3s.package;
      test = pkgs.testers.runNixOSTest {
        name = "helper-release-runtime";
        requiredFeatures.kvm = true;
        nodes = {
          publisher = { lib, ... }: {
            virtualisation = { cores = 1; memorySize = 1024; diskSize = 8192; };
            networking.firewall.allowedTCPPorts = [ 5000 ];
            environment.systemPackages = [ tool pkgs.git pkgs.nix pkgs.skopeo pkgs.openssl pkgs.curl pkgs.python3 pkgs.apacheHttpd ];
            nix.settings.experimental-features = [ "nix-command" "flakes" ];
            environment.etc."helper-source-a".source = sourceA;
            environment.etc."helper-source-b".source = sourceB;
            services.dockerRegistry = {
              enable = true;
              listenAddress = "0.0.0.0";
              extraConfig.http.tls = {
                certificate = "/run/helper-tls/server.crt";
                key = "/run/helper-tls/server.key";
              };
            };
            systemd.services.docker-registry.wantedBy = lib.mkForce [ ];
            systemd.services.docker-registry.serviceConfig.ExecStart =
              lib.mkForce "${pkgs.distribution}/bin/registry serve /run/helper-registry.json";
          };
          cluster = { lib, ... }: {
            virtualisation = { cores = 3; memorySize = 3072; diskSize = 8192; };
            environment.systemPackages = [ pkgs.curl ];
            services.k3s = {
              enable = true;
              package = k3s;
              role = "server";
              disable = [ "traefik" "servicelb" "local-storage" ];
              images = [ k3s.airgap-images ];
              extraFlags = [ "--disable-default-registry-endpoint" ];
            };
            systemd.services.k3s.wantedBy = lib.mkForce [ ];
          };
        };
        testScript = ''
          tool = "${tool}/bin/helper-release"
          kubectl = "${k3s}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
          k3s = "${k3s}/bin/k3s"
        '' + builtins.readFile ./helper-release-runtime.py;
      };
    in {
      checks.helper-release-runtime = test // {
        meta = test.meta // { hestia.group = "${system}-helper-release-runtime"; };
      };
      legacyPackages.helper-release-runtime-test = test;
    }
  );
}
