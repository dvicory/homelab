# Real pinned media services and producer jobs, on an owned Docker Linux volume.
# No live data/secrets; Kubernetes RBAC and Incus/MergerFS remain separate gates.
{ lib, ... }:
{
  perSystem = { pkgs, ... }:
    let
      source = lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.unions [
          ./media-live-acceptance.py
          ../../assets/media-policy
          ../../generated/manifests/prod-home
        ];
      };
      runner = pkgs.writeShellApplication {
        name = "media-live-acceptance";
        runtimeInputs = [
          (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
          pkgs.docker-client
          pkgs.openssl
        ];
        text = ''
          exec python ${source}/modules/tests/media-live-acceptance.py "$@"
        '';
      };
    in {
      packages.media-live-acceptance = runner;
      apps.media-live-acceptance = {
        type = "app";
        program = lib.getExe runner;
      };
    };
}
