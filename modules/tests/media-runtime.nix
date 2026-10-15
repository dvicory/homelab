# Real pinned media services and producer jobs, on an owned Docker Linux volume.
# No live data/secrets; Kubernetes RBAC and Incus/MergerFS remain separate gates.
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
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
          python
          pkgs.docker-client
          pkgs.openssl
        ];
        text = ''
          exec python ${source}/modules/tests/media-live-acceptance.py "$@"
        '';
      };
    in
    {
      checks.media-producer-exit =
        pkgs.runCommand "media-producer-exit" { nativeBuildInputs = [ python ]; }
          ''
            python - ${./media-live-acceptance.py} <<'PY'
            import runpy, sys
            require_exit = runpy.run_path(sys.argv[1])["require_application_exit"]
            require_exit(0, False, "successful producer")
            require_exit(1, True, "refusing producer")
            for status in (0, 2, 124, 125, 126, 127, 137, 143, -9):
                try:
                    require_exit(status, True, "refusing producer")
                except AssertionError:
                    continue
                raise AssertionError(f"exit {status} satisfied an application refusal")
            try:
                require_exit(1, False, "successful producer")
            except AssertionError:
                pass
            else:
                raise AssertionError("a failed producer satisfied success")
            print("producer exit policy accepts success/refusal and rejects unrelated failures")
            PY
            touch "$out"
          '';
      packages.media-live-acceptance = runner;
      apps.media-live-acceptance = {
        type = "app";
        program = lib.getExe runner;
      };
    };
}
