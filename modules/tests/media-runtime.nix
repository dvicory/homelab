# Real pinned media services and producer jobs, on an owned Docker Linux volume.
# No live data/secrets; Kubernetes RBAC and Incus/MergerFS remain separate gates.
{ lib, ... }:
{
  perSystem = { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.media-runtime = (pkgs.testers.runNixOSTest {
        name = "media-runtime";
        globalTimeout = 3000;
        requiredFeatures.kvm = true;
        nodes.machine = {
          system.stateVersion = "26.05";
          virtualisation = {
            cores = 4;
            memorySize = 8192;
            diskSize = 32768;
            restrictNetwork = false;
            docker.enable = true;
          };
          environment.systemPackages = [
            pkgs.openssl
            (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
          ];
        };
        testScript = let
          source = lib.fileset.toSource {
            root = ../..;
            fileset = lib.fileset.unions [
              ./media-live-acceptance.py
              ../../assets/media-policy
              ../../generated/manifests/prod-home
            ];
          };
        in ''
          start_all()
          machine.wait_for_unit("docker.service")
          machine.succeed(
              "python3 ${source}/modules/tests/media-live-acceptance.py "
              "--docker-host unix:///var/run/docker.sock --platform linux/amd64",
              timeout=2700,
          )
        '';
      }).overrideTestDerivation (_: {
        # Pinned registry pulls inside the disposable VM; hosted CI uses relaxed sandboxing.
        __noChroot = true;
      });
    };
}
