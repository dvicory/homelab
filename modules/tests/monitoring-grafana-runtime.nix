# Grafana's local administrator and the runbook's break-glass path, checked
# with the rendered Grafana objects and the pinned image in a K3s VM:
# - Grafana starts with an administrator password that only exists in
#   memory: no Secret holds it, and neither the login form nor basic
#   authentication accepts a sign-in;
# - the break-glass steps in docs/operations/monitoring.md (environment
#   override, `grafana cli admin reset-admin-password --password-from-stdin`,
#   port-forward) let a cluster administrator sign in as `admin`.
#
# Objects are applied server-side, as Argo CD does; the dashboards
# ConfigMap is too large for client-side apply. The two Secrets Grafana
# mounts hold test values. The VM pulls the Grafana
# image from its registry; the busybox image comes with K3s's airgap images.
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
        ++ map (
          { name, key }:
          {
            apiVersion = "v1";
            kind = "Secret";
            metadata = {
              inherit name;
              namespace = "monitoring";
            };
            stringData.${key} = "test-value-not-a-credential";
          }
        ) [
          {
            name = "grafana-oidc";
            key = "client-secret";
          }
          {
            name = "grafana-admin";
            key = "secret-key";
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
            import secrets

            kubectl = "${k3s.package}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n monitoring"

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

            with subtest("Grafana starts with an administrator password that exists only in memory"):
                rollout()
                secret_keys = json.loads(machine.succeed(f"{kubectl} get secret -o json"))["items"]
                stored = {s["metadata"]["name"]: sorted(s.get("data", {})) for s in secret_keys}
                assert stored == {"grafana-admin": ["secret-key"], "grafana-oidc": ["client-secret"]}, stored
                port_forward()
                status, _ = login(secrets.token_hex(16))
                assert status != 200, status
                basic = machine.succeed("curl -s -o /dev/null -w '%{http_code}' -u admin:wrong http://127.0.0.1:3000/api/user").strip()
                assert basic == "401", basic
                print(f"EVIDENCE only the secret key and OIDC Secrets exist; login form answers {status}, basic auth {basic}")

            with subtest("the runbook's break-glass steps sign the administrator in"):
                machine.succeed(
                    f"{kubectl} set env deployment/grafana GF_AUTH_DISABLE_LOGIN_FORM=false "
                    "GF_AUTH_OAUTH_AUTO_LOGIN=false GF_SERVER_ROOT_URL=http://localhost:3000/"
                )
                rollout()
                password = secrets.token_hex(24)
                out = machine.succeed(
                    f"printf '%s' {password} | {kubectl} exec -i deployment/grafana -c grafana -- "
                    "grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini "
                    "admin reset-admin-password --password-from-stdin 2>&1"
                )
                print(out)
                port_forward()
                status, cookie = login(password)
                assert status == 200 and cookie, (status, cookie)
                user = json.loads(machine.succeed(f"curl -sf -H 'Cookie: {cookie}' http://127.0.0.1:3000/api/user"))
                assert user["login"] == "admin" and user["isGrafanaAdmin"], user
                basic = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -u admin:{password} http://127.0.0.1:3000/api/user").strip()
                assert basic == "401", basic
                print("EVIDENCE after the override and reset-admin-password, admin signs in through the login form; basic auth stays off")
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
