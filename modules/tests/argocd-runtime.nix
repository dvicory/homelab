# Actual Argo reconciliation against disposable Git and Kubernetes resources.
# Claims: current-revision failed/missing child health, same-Application hook
# sequencing, workload self-heal, and retained PV/PVC identity plus data.
# Excludes app-of-apps startup barriers, media APIs, host/Incus mount propagation,
# backup/recovery, live credentials, and stale-status safety in the health Lua.
# Representative negatives (standard driver, bounded by globalTimeout):
# ARGOCD_RUNTIME_MUTATION=always-healthy ./result/bin/nixos-test-driver -o results-health
# ARGOCD_RUNTIME_MUTATION=cascade-retained ./result/bin/nixos-test-driver -o results-retention
{ lib, self, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        k3s = self.nixosConfigurations.compute-1.config.services.k3s.package;
        bootstrap = self.packages.${system}.household-bootstrap-manifests;
        manifests = ../../generated/manifests/prod-home;
        directories = self.packages.${system}.retained-directories-image;
        probe = pkgs.dockerTools.buildImage {
          name = "homelab/argocd-runtime-probe";
          tag = "1";
          copyToRoot = pkgs.buildEnv {
            name = "argocd-runtime-probe-root";
            paths = [ pkgs.busybox ];
            pathsToLink = [ "/bin" ];
          };
          config.Cmd = [ "/bin/sh" ];
        };
        settings = pkgs.writeText "argocd-runtime-settings.json" (builtins.toJSON {
          inherit bootstrap manifests;
          kubectl = "${k3s}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml --request-timeout=10s";
          probeImage = "${probe.imageName}:${probe.imageTag}";
          directoriesImage = directories.imageReference;
        });
      in
      {
        checks.argocd-runtime = (pkgs.testers.runNixOSTest {
          name = "argocd-runtime";
          globalTimeout = 1800;
          requiredFeatures.kvm = true;
          nodes.machine = {
            system.stateVersion = "26.05";
            virtualisation = {
              memorySize = 4096;
              cores = 4;
              diskSize = 16384;
              restrictNetwork = false;
            };
            environment.systemPackages = [ pkgs.git pkgs.jq pkgs.yq-go ];
            networking.firewall.allowedTCPPorts = [ 9418 ];
            services.k3s = {
              enable = true;
              role = "server";
              package = k3s;
              disable = [ "local-storage" "servicelb" "traefik" "metrics-server" ];
              images = [ k3s.airgap-images probe directories ];
            };
            systemd.services.argocd-runtime-git = {
              wantedBy = [ "multi-user.target" ];
              serviceConfig.ExecStart = "${pkgs.git}/bin/git daemon --reuseaddr --export-all --base-path=/srv/git --listen=0.0.0.0 /srv/git";
              serviceConfig.Restart = "on-failure";
              preStart = "mkdir -p /srv/git";
            };
          };
          testScript = ''
            import json
            settings = json.loads(open("${settings}").read())
            exec(compile(open("${./_argocd-runtime/scenario.py}").read(), "argocd-runtime/scenario.py", "exec"))
          '';
        }).overrideTestDerivation (_: {
          # Pinned registry pulls; hosted CI uses relaxed sandboxing.
          __noChroot = true;
        });
      }
    );
}
