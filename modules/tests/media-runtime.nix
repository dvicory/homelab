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
          exec python ${source}/modules/tests/media-live-acceptance.py --seerr-phases ${seerrPhases} "$@"
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
