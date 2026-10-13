{
  config,
  lib,
  self,
  ...
}:
let
  domain = builtins.head config.den.clusters."prod-home".routes.idm.hostnames;
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.household-sign-in-runtime =
        (pkgs.testers.runNixOSTest {
          name = "household-sign-in-runtime";
          globalTimeout = 3600;
          requiredFeatures.kvm = true;
          nodes.machine = {
            system.stateVersion = "26.05";
            networking.hosts."127.0.0.1" = [ domain ];
            virtualisation = {
              cores = 4;
              memorySize = 6144;
              diskSize = 16384;
              restrictNetwork = false;
              docker.enable = true;
            };
            environment.systemPackages = [
              pkgs.openssl
              pkgs.openldap
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
            ];
          };
          testScript =
            let
              packages = self.packages.${system};
              images = [
                packages.kanidm-provision-image
                packages.jellyfin-provisioner-image
                packages.jellyfin-plugins-image
                packages.jellarr-image
              ];
              source = lib.fileset.toSource {
                root = ../..;
                fileset = lib.fileset.unions [
                  ./household-sign-in-runtime.py
                  ../../generated/manifests/prod-home
                ];
              };
            in
            ''
              start_all()
              machine.wait_for_unit("docker.service")
            ''
            + lib.concatMapStrings (image: ''
              machine.succeed("docker load < ${image}")
            '') images
            + ''
              status, output = machine.execute(
                  "python3 ${source}/modules/tests/household-sign-in-runtime.py --domain ${domain} 2>&1",
                  timeout=3000,
              )
              print(output)
              assert status == 0, f"household sign-in exited {status}"
            '';
        }).overrideTestDerivation
          (_: {
            __noChroot = true;
          });
    };
}
