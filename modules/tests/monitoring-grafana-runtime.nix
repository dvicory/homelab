# Check managed-file password initialization, normal local-auth refusal and
# deliberate private emergency sign-in against rendered Grafana objects and
# the pinned image in a K3s VM. No CLI reset may bypass initial credentials.
#
# Objects are applied server-side, as Argo CD does; the dashboards ConfigMap
# is too large for client-side apply. The two Secrets hold FAKE fixture
# material only. No HTTPRoute is installed: emergency access stays private.
# The VM pulls the Grafana image from its registry.
{ lib, self, ... }:
let
  compute = self.nixosConfigurations.compute-1.config;
  k3s = compute.services.k3s;
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      # Native rendering remains covered by prod-home-manifests-fresh.
      rendered = ../../generated/manifests/prod-home;
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      fakeAdminPassword = "FakeManagedGrafanaAdminPasswordForRuntimeOnly123456";
      testObjects = builtins.toJSON {
        apiVersion = "v1";
        kind = "List";
        items = [
          {
            apiVersion = "v1";
            kind = "Namespace";
            metadata.name = "monitoring";
          }
        ]
        ++
          map
            (
              { name, data }:
              {
                apiVersion = "v1";
                kind = "Secret";
                metadata = {
                  inherit name;
                  namespace = "monitoring";
                };
                stringData = data;
              }
            )
            [
              {
                name = "grafana-oidc";
                data.client-secret = "FAKE-OIDC-CLIENT-SECRET";
              }
              {
                name = "grafana-admin";
                data = {
                  secret-key = "FAKE-GRAFANA-SECRET-KEY";
                  admin-password = fakeAdminPassword;
                };
              }
            ];
      };
      manifests = pkgs.runCommand "grafana-test-objects.json" { nativeBuildInputs = [ python ]; } ''
        python - ${rendered} > "$out" <<'PY'
        import json, sys
        from pathlib import Path
        import yaml
        manifest = json.loads(${builtins.toJSON testObjects})
        for kind, name in (
            ("ServiceAccount", "grafana"), ("ConfigMap", "grafana"),
            ("ConfigMap", "grafana-dashboards"), ("Service", "grafana"), ("Deployment", "grafana"),
            ("ConfigMap", "alertmanager-config"), ("Service", "alertmanager"), ("Deployment", "alertmanager"),
        ):
            path = Path(sys.argv[1]) / "monitoring" / f"{kind}-{name}.yaml"
            manifest["items"].append(yaml.safe_load(path.read_text()))
        json.dump(manifest, sys.stdout)
        PY
      '';
      test =
        (pkgs.testers.runNixOSTest {
          name = "monitoring-grafana-runtime";
          requiredFeatures.kvm = true;
          nodes.machine = {
            system.stateVersion = "26.05";
            networking.hostName = compute.networking.hostName;
            networking.firewall.enable = false;
            virtualisation = {
              cores = 2;
              memorySize = 3072;
              diskSize = 8192;
              restrictNetwork = false;
            };
            environment.systemPackages = [
              pkgs.curl
              pkgs.python3
            ];
            environment.etc."grafana-test/objects.json".source = manifests;
            services.k3s = {
              enable = true;
              role = "server";
              inherit (k3s) package disable extraFlags;
              images = [ k3s.package.airgap-images ];
            };
          };
          testScript = ''
            import json
            from datetime import datetime, timedelta, timezone

            kubectl = "${k3s.package}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n monitoring"
            password = ${builtins.toJSON fakeAdminPassword}

            def port_forward():
                machine.execute("systemctl stop grafana-forward.service; systemctl reset-failed grafana-forward.service")
                machine.succeed(f"systemd-run --unit grafana-forward {kubectl} port-forward svc/grafana 3000:80")
                machine.wait_until_succeeds("curl -sf http://127.0.0.1:3000/api/health", timeout=60)

            def login(password):
                # Returns the HTTP status and, on success, the session cookie.
                body = json.dumps({"user": "admin", "password": password})
                out = machine.succeed(
                    f"curl -s -o /dev/null -D - -w '%{{http_code}}' -H 'Content-Type: application/json' "
                    f"--data '{body}' http://127.0.0.1:3000/login"
                )
                status = int(out.strip().splitlines()[-1])
                cookie = ""
                for line in out.splitlines():
                    if line.lower().startswith("set-cookie: grafana_session="):
                        cookie = line.split(":", 1)[1].split(";", 1)[0].strip()
                return status, cookie

            def rollout():
                machine.wait_until_succeeds(f"{kubectl} rollout status deployment/grafana --timeout=30s", timeout=900)

            start_all()
            machine.wait_for_unit("k3s.service")
            machine.wait_until_succeeds(f"{kubectl} get node -o name | grep -q node", timeout=300)
            machine.wait_until_succeeds(f"{kubectl} wait --for=condition=Ready node --all --timeout=10s", timeout=300)
            machine.wait_until_succeeds(f"{kubectl} apply --server-side -f /etc/grafana-test/objects.json", timeout=120)

            with subtest("normal configuration refuses known-valid local administrator credentials"):
                rollout()
                port_forward()
                status, cookie = login(password)
                assert 400 <= status < 500 and not cookie, (status, bool(cookie))
                basic = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -u admin:{password} http://127.0.0.1:3000/api/user").strip()
                assert basic == "401", basic
                print(f"EVIDENCE known-valid local credentials refused: login {status}, basic auth {basic}")

            with subtest("the runbook's break-glass steps sign the administrator in"):
                machine.succeed(
                    f"{kubectl} set env deployment/grafana GF_AUTH_DISABLE_LOGIN_FORM=false "
                    "GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=false GF_SERVER_ROOT_URL=http://localhost:3000/ "
                    "GF_SECURITY_COOKIE_SECURE=false"
                )
                rollout()
                port_forward()
                for rejected in ("admin", "WrongFakeManagedPassword"):
                    status, rejected_cookie = login(rejected)
                    assert 400 <= status < 500 and not rejected_cookie, (status, bool(rejected_cookie))
                status, cookie = login(password)
                assert status == 200 and cookie, (status, cookie)
                user = json.loads(machine.succeed(f"curl -sf -H 'Cookie: {cookie}' http://127.0.0.1:3000/api/user"))
                assert user["login"] == "admin" and user["isGrafanaAdmin"], user
                basic = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -u admin:{password} http://127.0.0.1:3000/api/user").strip()
                assert basic == "401", basic
                print("EVIDENCE the managed file seeded native initial admin credentials without a CLI reset; private form sign-in works and basic auth stays off")

            with subtest("Grafana manages a real external Alertmanager silence"):
                machine.wait_until_succeeds(f"{kubectl} rollout status deployment/alertmanager --timeout=30s", timeout=300)
                endpoint = "http://127.0.0.1:3000/api/alertmanager/alertmanager/api/v2/silences"
                now = datetime.fromtimestamp(float(machine.succeed("date +%s.%N")), timezone.utc)
                silence = json.dumps({
                    "matchers": [{"name": "alertname", "value": "GrafanaSilenceRegression", "isRegex": False, "isEqual": True}],
                    "startsAt": now.isoformat(),
                    "endsAt": (now + timedelta(hours=1)).isoformat(),
                    "createdBy": "disposable-runtime-check",
                    "comment": "External Alertmanager silence regression",
                })
                response = json.loads(machine.succeed(
                    f"curl -sf -H 'Cookie: {cookie}' -H 'Content-Type: application/json' --data '{silence}' {endpoint}"
                ))
                silence_id = response["silenceID"]
                active = json.loads(machine.succeed(f"curl -sf -H 'Cookie: {cookie}' {endpoint}"))
                assert any(item["id"] == silence_id and item["status"]["state"] == "active" for item in active), active
                machine.succeed(f"curl -sf -X DELETE -H 'Cookie: {cookie}' {endpoint[:-1]}/{silence_id}")
                expired = json.loads(machine.succeed(f"curl -sf -H 'Cookie: {cookie}' {endpoint}"))
                assert any(item["id"] == silence_id and item["status"]["state"] == "expired" for item in expired), expired
                print("EVIDENCE authenticated Grafana created, listed and expired a silence in the real external Alertmanager")

            with subtest("normal authentication is restored before any entrance could be republished"):
                machine.succeed(
                    f"{kubectl} set env deployment/grafana GF_AUTH_DISABLE_LOGIN_FORM- "
                    "GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN- GF_SERVER_ROOT_URL- GF_SECURITY_COOKIE_SECURE-"
                )
                rollout()
                port_forward()
                status, cookie = login(password)
                assert 400 <= status < 500 and not cookie, (status, bool(cookie))
                basic = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -u admin:{password} http://127.0.0.1:3000/api/user").strip()
                assert basic == "401", basic
          '';
        }).overrideTestDerivation
          (_: {
            # The VM pulls the pinned Grafana image from its registry.
            __noChroot = true;
          });
    in
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        monitoring-grafana-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-monitoring-grafana-runtime";
          };
        };
      };
    };
}
