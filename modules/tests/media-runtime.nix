# Real pinned media services and producer jobs, on an owned Docker Linux volume.
# No live data/secrets; Kubernetes RBAC and Incus/MergerFS remain separate gates.
{ config, lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      # Freeze both sides of the old API/image pair independently of this checkout.
      oldHomelab = builtins.fetchTree {
        type = "github";
        owner = "dvicory";
        repo = "homelab";
        rev = "90920bac376c6640478c1c45feaf6afa2c1c3900";
        narHash = "sha256-2KHmKX0smBDl3Pk554o30z44RxN2sAP1yX5gPvImSBM=";
      };
      cluster = config.den.clusters.prod-home;
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      computeResources = {
        inherit (compute) accelerator instance retainedPaths;
        inherit (config.flake.clusterResources.prod-home) mediaPaths;
      };
      fixtureCluster = lib.recursiveUpdate cluster {
        settings.kubernetes.services.jellyfin.administrator = "Jellyfin Admin";
      };
      configurationFor =
        targetCluster:
        (config.den.aspects.kubernetes.services.media.configuration."k8s-manifests" {
          cluster = targetCluster;
          inherit computeResources;
        }).applications.media-configuration.objects;
      jellyfinApplications =
        (config.den.aspects.kubernetes.services.jellyfin."k8s-manifests" {
          cluster = fixtureCluster;
          inherit computeResources;
        }).applications;
      objectFor =
        kind: name: objects:
        lib.findFirst (
          object: object.kind == kind && object.metadata.name == name
        ) (throw "Missing native media fixture ${kind}/${name}") objects;
      fixture = pkgs.writeText "media-native-fixture.json" (
        builtins.toJSON {
          jellyfinPod =
            (objectFor "Deployment" "jellyfin" jellyfinApplications.jellyfin.objects).spec.template.spec;
          jellarrPod =
            (objectFor "Job" "jellyfin-configuration" jellyfinApplications.jellyfin-configuration.objects)
            .spec.template.spec;
          jellarrData =
            (objectFor "ConfigMap" "jellarr-configuration" jellyfinApplications.jellyfin-configuration.objects)
            .data;
          configuration =
            (objectFor "ConfigMap" "media-configuration" (configurationFor fixtureCluster)).data;
          changedAdministratorConfiguration =
            (objectFor "ConfigMap" "media-configuration" (
              configurationFor (
                lib.recursiveUpdate fixtureCluster {
                  settings.kubernetes.services.jellyfin.administrator = "Another Administrator";
                }
              )
            )).data;
          # Fresh onboarding must not depend on production's publication phase.
          seerrPhases = lib.genAttrs [ "initial" "ready" ] (
            phase:
            objectFor "Job" "media-config-seerr" (
              configurationFor (
                lib.recursiveUpdate fixtureCluster {
                  settings.kubernetes.services.seerr.phase = phase;
                }
              )
            )
          );
        }
      );
      source = lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.unions [
          ./media-live-acceptance.py
          ../../generated/manifests/prod-home
          ../../assets/media-policy
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
          exec python ${source}/modules/tests/media-live-acceptance.py --fixture ${fixture} --seerr-baseline ${oldHomelab} "$@"
        '';
      };
    in
    {
      checks.media-producer-exit =
        pkgs.runCommand "media-producer-exit" { nativeBuildInputs = [ python ]; }
          ''
            python - ${./media-live-acceptance.py} <<'PY'
            import contextlib, io, re, runpy, subprocess, sys
            acceptance = runpy.run_path(sys.argv[1])
            difference = acceptance["state_difference"]
            assert difference({"id": 1}, {"id": 1}) == []
            assert difference({"id": 1}, {"id": 2}) == [
                {"path": ["id"], "before": 1, "after": 2}
            ]
            assert difference({"optional": None}, {}) == [
                {"path": ["optional"], "before": None, "after": "missing"}
            ]
            redacted = difference(
                {"fields": [{"value": "synthetic-secret-before"}]},
                {"fields": [{"value": "synthetic-secret-after"}]},
            )
            assert redacted == [{"path": ["fields", "0", "value"], "before": "str", "after": "str"}]
            assert len(difference(list(range(100)), list(range(1, 101)))) == 16
            profile_difference = acceptance["quality_profile_difference"]
            profile = {"id": 41, "name": "arbitrary-private-native-name", "cutoff": 7,
                       "items": [{"quality": {"id": 0}, "allowed": False, "items": []},
                                 {"id": 1001, "allowed": True, "items": [
                                     {"quality": {"id": 7}, "allowed": True, "items": []}]}],
                       "formatItems": [{"format": 5, "score": 1700}]}
            before = {app: {"/qualityprofile": [acceptance["deepcopy"](profile)]}
                      for app in ("radarr", "sonarr")}
            after = acceptance["deepcopy"](before)
            after["radarr"]["/qualityprofile"][0]["items"].reverse()
            policy_diff = profile_difference(before, after, {"radarr": set(), "sonarr": set()},
                                             {"radarr": {"id": 41}, "sonarr": {"id": 42}})
            assert policy_diff["changedProfileCount"] == 1
            old, new = (policy_diff["profiles"][0][key] for key in ("before", "after"))
            assert old["id"] == new["id"] == 41 and old["category"] == new["category"] == "ui-owned"
            assert old["enabledOrder"] == new["enabledOrder"] == [1001]
            assert old["qualities"] != new["qualities"] and old["formatScores"] == new["formatScores"] == [[5, 1700]]
            assert "arbitrary-private-native-name" not in repr(policy_diff)
            require_exit = acceptance["require_application_exit"]
            require_exit(0, False, "successful producer")
            require_exit(1, True, "refusing producer")
            for status in (0, 2, 124, 125, 126, 127, 134, 137, 143, -9):
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

            secret = "generated-owner-password"
            for name in ("jellyfin-provision", "jellarr-bootstrap"):
                result = subprocess.CompletedProcess(
                    ["docker", "run"], 134,
                    stdout="early-log " + "\u2603" * 3000
                        + f"\n/cache has insufficient free space\n{secret}\x1b[31m",
                    stderr=f"Unhandled exception\n{secret}\n",
                )
                captured = io.StringIO()
                with contextlib.redirect_stderr(captured):
                    try:
                        require_container_exit(result, False, name, diagnostic_secrets=(secret,))
                    except AssertionError as error:
                        assert "exit 134, expected 0" in str(error)
                    else:
                        raise AssertionError("bootstrap crash satisfied success")
                output = captured.getvalue()
                assert "/cache has insufficient free space" in output and "Unhandled exception" in output
                assert secret not in output and output.count("[redacted]") == 2
                assert "[truncated]" in output and "early-log" not in output
                assert len(output.encode()) <= 16600
                assert "\x1b" not in output and output.isascii()
                for status, failure in ((0, False), (1, True)):
                    captured = io.StringIO()
                    with contextlib.redirect_stderr(captured):
                        require_container_exit(completed(status), failure, name, diagnostic_secrets=(secret,))
                    assert not captured.getvalue(), "expected helper outcome emitted private output"
            failure_label = acceptance["failure_label"]
            secret = "synthetic-credential-must-not-appear"
            try:
                acceptance["request_from_container"](
                    lambda *args: '{"status": 403, "body": "untrusted-response-body"}',
                    "fixture", "credential-bearing-host.invalid",
                    "/api?apikey=" + secret, key=secret, body={"password": secret},
                )
            except acceptance["HTTPError"] as error:
                label = failure_label(error)
                assert "HTTPError" in label and "HTTP 403" in label
                assert re.search(r"media-live-acceptance[.]py:[0-9]+(?:,[0-9]+)*", label)
                assert label.isascii()
                assert not any(value in label for value in (
                    secret, "credential-bearing-host", "/api", "untrusted-response-body", "http://fixture",
                ))
            else:
                raise AssertionError("unexpected HTTP refusal did not reach the diagnostic boundary")
            unsafe = acceptance["HTTPError"](
                "https://host.invalid/?apikey=" + secret, 401, secret, {"credential": secret}, io.StringIO(secret),
            )
            label = failure_label(unsafe)
            assert "HTTPError" in label and "HTTP 401" in label
            assert secret not in label and "host.invalid" not in label
            assert failure_label(ValueError(secret)) == "ValueError"
            for items, field, expected in (([{}], secret, KeyError), (None, "name", TypeError)):
                try:
                    acceptance["one"](items, field, secret)
                except expected as error:
                    label = failure_label(error)
                    assert expected.__name__ in label
                    assert re.search(r"media-live-acceptance[.]py:[0-9]+(?:,[0-9]+)*", label)
                    assert secret not in label and label.isascii()
                else:
                    raise AssertionError("unexpected native-data failure did not reach the diagnostic boundary")
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
