# Real pinned media services and producer jobs, on an owned Docker Linux volume.
# No live data/secrets; Kubernetes RBAC and Incus/MergerFS remain separate gates.
{ config, lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      cluster = config.den.clusters.prod-home;
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      computeResources = {
        inherit (compute) instance retainedPaths;
        inherit (config.flake.clusterResources.prod-home) mediaPaths;
      };
      # Fresh-state onboarding must not depend on production's publication phase.
      seerrPhases = pkgs.writeText "media-seerr-phase-fixtures.json" (
        builtins.toJSON (
          lib.genAttrs [ "initial" "ready" ] (
            phase:
            let
              applications =
                (config.den.aspects.kubernetes.services.media.configuration."k8s-manifests" {
                  cluster = cluster // {
                    settings = lib.recursiveUpdate cluster.settings {
                      kubernetes.services.seerr.phase = phase;
                    };
                  };
                  inherit computeResources;
                }).applications;
            in
            builtins.head (
              builtins.filter (
                object: object.kind == "Job" && object.metadata.name == "media-config-seerr"
              ) applications.media-configuration.objects
            )
          )
        )
      );
      source = lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.unions [
          ./media-live-acceptance.py
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
          exec python ${source}/modules/tests/media-live-acceptance.py --seerr-phases ${seerrPhases} "$@"
        '';
      };
    in
    {
      checks.media-producer-exit =
        pkgs.runCommand "media-producer-exit" { nativeBuildInputs = [ python ]; }
          ''
            python - ${./media-live-acceptance.py} <<'PY'
            import contextlib, io, runpy, subprocess, sys
            acceptance = runpy.run_path(sys.argv[1])
            require_exit = acceptance["require_application_exit"]
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
            require_container_exit = acceptance["require_container_exit"]
            diagnostic = (
                'docker: Error response from daemon: Get "https://registry.invalid/v2/": connection reset\n'
                "\x1b[31m::error::untrusted output\n" + "\u2603" * 3000
            )
            def completed(status):
                return subprocess.CompletedProcess(
                    ["docker", "run"], status,
                    stdout="unrelated-container-stdout", stderr=diagnostic,
                )

            result = completed(125)
            captured = io.StringIO()
            with contextlib.redirect_stderr(captured):
                try:
                    require_container_exit(result, False, "fixture")
                except AssertionError:
                    pass
                else:
                    raise AssertionError("Docker startup failure satisfied fixture success")
            output = captured.getvalue()
            assert "connection reset" in output and "https://registry.invalid/v2/" in output
            assert "unrelated-container-stdout" not in output
            assert len(output.encode()) <= 2200
            assert "\x1b" not in output and output.isascii()

            for name, status, failure in (
                ("fixture", 0, False),
                ("producer", 0, False),
                ("producer", 1, True),
                ("producer", 125, False),
            ):
                captured = io.StringIO()
                with contextlib.redirect_stderr(captured):
                    try:
                        require_container_exit(completed(status), failure, name)
                    except AssertionError:
                        assert status == 125 and name != "fixture"
                    else:
                        assert status != 125
                assert not captured.getvalue(), "successful setup or later producer emitted startup diagnostics"
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
