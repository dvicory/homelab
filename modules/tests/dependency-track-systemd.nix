# This VM qualifies the source units, not another live-inventory import. Its
# credentials are generated inside the disposable VM; no token enters a derivation.
{
  config,
  inputs,
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      base =
        inputs.flake-parts.lib.mkFlake
          {
            inputs = inputs // {
              inherit self;
            };
          }
          {
            imports = [ (inputs.import-tree [ (self.outPath + "/modules") ]) ];
            debug = true;
          };
      selected = base.debug.extendModules {
        modules = [
          ({ den, ... }: {
            den.aspects.prod-home.includes = [ den.aspects.kubernetes.services.dependency-track ];
            den.clusters.prod-home.settings.kubernetes.services.dependency-track = {
              databasePhase = "bootstrap";
              privateAccess = true;
              automaticInventory = true;
            };
            den.aspects.compute-1.includes = [ den.aspects.workloads.dependency-track-sync.compute-guest ];
            den.hosts.x86_64-linux.compute-1.settings.workloads.dependency-track-sync.apiUrl =
              "http://127.0.0.1:1022";
          })
        ];
      };
      source = selected.config;
      host = source.den.hosts.x86_64-linux.compute-1;
      workload =
        (import ../den/aspects/workloads/dependency-track-sync.nix {
          config = source;
          den = source.den;
          inherit inputs lib;
        }).den.aspects.workloads.dependency-track-sync;
      kubernetes =
        (import ../den/aspects/services/kubernetes.nix { inherit inputs; }).den.aspects.services.kubernetes;
      service =
        (import ../den/aspects/kubernetes/services/dependency-track.nix {
          config = source;
          inherit inputs lib;
        }).den.aspects.kubernetes.services.dependency-track;
      cluster = source.den.clusters.prod-home;
      retainedPaths = lib.mapAttrs (
        name: value:
        value
        // {
          guestPath = "/srv/state/${name}";
          readOnly = false;
        }
      ) (service.compute-resources { inherit cluster; }).retainedPaths;
      render =
        databasePhase:
        service.k8s-manifests {
          cluster = lib.recursiveUpdate cluster {
            # Browser/OIDC qualification lives in the native fixture. This VM
            # exercises stock bootstrap/restore API policy before identity cutover.
            settings.kubernetes.services.identity.phase = "initial";
            settings.kubernetes.services.dependency-track = {
              inherit databasePhase;
              automaticInventory = false;
            };
          };
          computeResources = {
            inherit retainedPaths;
            instance = "compute-1";
          };
        };
      bootstrap = render "bootstrap";
      retained = bootstrap.applications.dependency-track-retained.resources;
      manifest =
        name: items:
        pkgs.writeText name (
          builtins.toJSON {
            apiVersion = "v1";
            kind = "List";
            inherit items;
          }
        );
      volumes =
        lib.mapAttrsToList (
          name: value:
          value
          // {
            apiVersion = "v1";
            kind = "PersistentVolume";
            metadata = value.metadata // {
              inherit name;
            };
          }
        ) retained.persistentVolumes
        ++ lib.mapAttrsToList (
          name: value:
          value
          // {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            metadata = value.metadata // {
              inherit name;
              namespace = "dependency-track";
            };
          }
        ) retained.persistentVolumeClaims;
      monitoring =
        (import ../den/aspects/kubernetes/services/monitoring/alerting.nix {
          inherit config inputs lib;
        }).den.aspects.kubernetes.services.monitoring.alerting.k8s-manifests
          {
            cluster = config.den.clusters.prod-home;
            computeResources = config.flake.clusterResources.prod-home;
            charts = { };
          };
      amContainer =
        monitoring.applications.monitoring.helm.releases.alertmanager.values.controllers.main.containers.alertmanager;
      amConfig = builtins.fromJSON (
        (lib.findSingle
          (object: object.kind == "ConfigMap" && object.metadata.name == "alertmanager-config")
          (throw "Missing source Alertmanager configuration")
          (throw "Ambiguous source Alertmanager configuration")
          monitoring.applications.monitoring.objects
        ).data."alertmanager.yaml"
      );
      eventRoute =
        lib.findSingle
          (route: builtins.elem "alertname=\"DependencyTrackInventoryRefreshFailed\"" (route.matchers or [ ]))
          (throw "Missing source inventory event route")
          (throw "Ambiguous source inventory event route")
          amConfig.route.routes;
      alertmanager = manifest "dependency-track-unit-alertmanager.json" [
        {
          apiVersion = "v1";
          kind = "Namespace";
          metadata.name = "monitoring";
        }
        {
          apiVersion = "v1";
          kind = "ConfigMap";
          metadata = {
            name = "unit-alertmanager";
            namespace = "monitoring";
          };
          data."alertmanager.json" = builtins.toJSON {
            route = amConfig.route // {
              routes = [ eventRoute ];
            };
            # Preserve route/receiver identities, but never configure a provider.
            receivers = map (receiver: { inherit (receiver) name; }) amConfig.receivers;
          };
        }
        {
          apiVersion = "v1";
          kind = "Pod";
          metadata = {
            name = "unit-alertmanager";
            namespace = "monitoring";
            labels.app = "unit-alertmanager";
          };
          spec = {
            automountServiceAccountToken = false;
            containers = [
              {
                name = "alertmanager";
                image = "${amContainer.image.repository}:${amContainer.image.tag}";
                args = [
                  "--config.file=/config/alertmanager.json"
                  "--storage.path=/tmp/am"
                  "--cluster.listen-address="
                ];
                resources = amContainer.resources;
                ports = [ { containerPort = 9093; } ];
                readinessProbe.httpGet = {
                  path = "/-/ready";
                  port = 9093;
                };
                volumeMounts = [
                  {
                    name = "config";
                    mountPath = "/config";
                    readOnly = true;
                  }
                ];
              }
            ];
            volumes = [
              {
                name = "config";
                configMap.name = "unit-alertmanager";
              }
            ];
          };
        }
        {
          apiVersion = "v1";
          kind = "Service";
          metadata = {
            name = "alertmanager";
            namespace = "monitoring";
          };
          spec = {
            selector.app = "unit-alertmanager";
            ports = [
              {
                name = "http";
                port = 9093;
                targetPort = 9093;
              }
            ];
          };
        }
      ];
      syncPackage = pkgs.callPackage ../../pkgs/by-name/dependency-track-sync/package.nix { };
      # This extra unprivileged pre-start observation runs *inside* the real
      # importer's credential/mount/user sandbox. It replaces no source command.
      probe = pkgs.writeText "dependency-track-unit-probe.py" ''
        import hashlib
        import json
        import os
        from pathlib import Path
        import subprocess
        import time

        assert os.getuid() == os.getgid() == 705
        assert "NoNewPrivs:\t1" in Path("/proc/self/status").read_text()
        state = Path("/srv/state/dependency-track-evidence")
        credentials = Path(os.environ["CREDENTIALS_DIRECTORY"])
        hashes = {}
        for key in ("api-key", "github-token"):
            path = credentials / key
            assert path.stat().st_mode & 0o777 == 0o400
            hashes[key] = hashlib.sha256(path.read_bytes()).hexdigest()
        for path in ("/etc/rancher/k3s/k3s.yaml",
                     "/run/dependency-track-sync-credentials/api-key",
                     "/srv/secrets/runtime-secrets.yaml",
                     "/run/dt-unit-fixture/secrets.json",
                     "/run/dependency-track-sync-api-tunnel/pod.json"):
            try:
                Path(path).read_bytes()
            except PermissionError:
                pass
            else:
                raise AssertionError("705 read a root-only resource")
        try:
            Path("/etc/dt-unit-write-refused").write_text("forbidden")
        except OSError:
            pass
        else:
            raise AssertionError("unit escaped ProtectSystem")
        env = dict(os.environ, NIX_REMOTE="daemon")
        def run(arguments):
            return subprocess.run(arguments, env=env, check=True, capture_output=True,
                                  text=True, timeout=30).stdout
        ping = json.loads(run(["${pkgs.nix}/bin/nix", "--extra-experimental-features", "nix-command",
                               "store", "ping", "--json"]))
        assert ping["trusted"] is False
        assert json.loads(run(["${pkgs.nix}/bin/nix", "--extra-experimental-features", "nix-command",
                               "eval", "--impure", "--json", "--expr",
                               'builtins.storePath "${syncPackage}"'])) == "${syncPackage}"
        result = {"uid": os.getuid(), "gid": os.getgid(), "hashes": hashes,
                  "nixDaemonTrusted": ping["trusted"], "pid": os.getpid()}
        (state / "unit-probe.json").write_text(json.dumps(result))
        # A runtime-only hold permits stop/cleanup observation; it grants no root action.
        deadline = time.monotonic() + 90
        while (state / "unit-probe-hold").exists():
            assert time.monotonic() < deadline
            time.sleep(0.1)
      '';
      fixture = pkgs.writeText "dependency-track-unit-fixture.py" ''
        import base64
        from datetime import datetime
        import hashlib
        import json
        import os
        from pathlib import Path
        import secrets
        import subprocess
        import sys
        import urllib.error
        import urllib.parse
        import urllib.request
        import uuid

        os.umask(0o077)
        root = Path("/run/dt-unit-fixture")
        root.mkdir(mode=0o700, exist_ok=True)
        secret_file = root / "secrets.json"
        if not secret_file.exists():
            secret_file.write_text(json.dumps({key: secrets.token_hex(32) for key in
                                              ("postgres", "admin", "api-key", "github-token")}))
        values = json.loads(secret_file.read_text())
        kube = ["${lib.getExe' self.nixosConfigurations.compute-1.config.services.k3s.package.k3sBundle "kubectl"}",
                "--kubeconfig=/etc/rancher/k3s/k3s.yaml", "--request-timeout=15s"]
        def k(*args, data=None):
            process = subprocess.run(kube + list(args), input=data, capture_output=True, timeout=40)
            if process.returncode:
                raise RuntimeError("fixture Kubernetes operation failed")
            return process.stdout
        def resource(kind, name):
            return json.loads(k("-n", "dependency-track", "get", kind, name, "-o", "json"))
        def pod():
            items = json.loads(k("-n", "dependency-track", "get", "pods", "-l",
                                 "app.kubernetes.io/name=dependency-track-api", "-o", "json"))["items"]
            items = [item for item in items if not item["metadata"].get("deletionTimestamp")]
            assert len(items) == 1
            return items[0]
        def request(url, *, form=None, token=None):
            headers = {} if token is None else {"Authorization": "Bearer " + token}
            data = None if form is None else urllib.parse.urlencode(form).encode()
            if data is not None:
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            req = urllib.request.Request(url, data, headers)
            try:
                with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=5) as response:
                    return response.status, response.read()
            except urllib.error.HTTPError as error:
                return error.code, error.read()
        def stage(mode):
            if mode == "rotate":
                for key in ("api-key", "github-token"):
                    values[key] = secrets.token_hex(32)
                secret_file.write_text(json.dumps(values))
            resources = []
            def secret(name, data):
                resources.append({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                                  "metadata": {"name": name, "namespace": "dependency-track"},
                                  "data": {key: base64.b64encode(value.encode()).decode()
                                           for key, value in data.items()}})
            secret("dependency-track-postgres", {"password": values["postgres"]})
            if mode != "missing-admin":
                secret("dependency-track-admin", {"password": secrets.token_hex(32)
                       if mode == "wrong-admin" else values["admin"]})
            if mode != "bootstrap":
                data = {key: values[key] for key in ("api-key", "github-token")}
                if mode == "missing-key":
                    del data["github-token"]
                secret("dependency-track-sync", data)
            history_file = root / "credential-history.json"
            history = json.loads(history_file.read_text()) if history_file.exists() else []
            history += [base64.b64decode(value).decode() for item in resources for value in item["data"].values()]
            history_file.write_text(json.dumps(sorted(set(history))))
            yaml = "".join(json.dumps(item, sort_keys=True) + "\n---\n" for item in resources)
            names = "".join(sorted("dependency-track\t" + item["metadata"]["name"] +
                                   "\tOpaque\t" + ",".join(sorted(item["data"])) + "\n"
                                   for item in resources))
            yh = hashlib.sha256(yaml.encode()).hexdigest()
            nh = hashlib.sha256(names.encode()).hexdigest()
            generation = hashlib.sha256((yh + "\n" + nh + "\n").encode()).hexdigest()
            directory = Path("/srv/secrets")
            for name, text in (("yaml", yaml), ("names", names),
                               ("commit", f"generation={generation} yaml-sha256={yh} names-sha256={nh}\n")):
                temporary = directory / ("runtime-secrets." + name + ".new")
                temporary.write_text(text)
                temporary.chmod(0o400)
                temporary.replace(directory / ("runtime-secrets." + name))
        command = sys.argv[1]
        if command == "stage":
            stage(sys.argv[2])
        elif command == "gate":
            admitted = sys.argv[2] == "true"
            current = pod()
            conditions = {item["type"]: item["status"] for item in current["status"].get("conditions", [])}
            assert (conditions.get("security.homelab/access-policy-ready") == "True") == admitted
            assert conditions["ContainersReady"] == "True"
            endpoints = json.loads(k("-n", "dependency-track", "get", "endpointslices", "-l",
                                     "kubernetes.io/service-name=dependency-track-api", "-o", "json"))
            ready = [endpoint for item in endpoints["items"] for endpoint in item.get("endpoints", [])
                     if endpoint.get("conditions", {}).get("ready") is True]
            assert bool(ready) == admitted
            if admitted:
                assert all(item["targetRef"]["uid"] == current["metadata"]["uid"] for item in ready)
            svc = resource("service", "dependency-track-api")
            assert not svc["spec"].get("publishNotReadyAddresses", False)
            try:
                status, _ = request("http://" + svc["spec"]["clusterIP"] + ":8080/api/version")
            except (OSError, urllib.error.URLError):
                assert not admitted
            else:
                assert admitted and status == 200
        elif command == "auth":
            url = "http://127.0.0.1:1022/api/v1/user/"
            status, body = request(url + "login", form={"username": "admin", "password": "admin"})
            assert (status, body) == (401, b"INVALID_CREDENTIALS")
            status, body = request(url + "login", form={"username": "admin", "password": values["admin"]})
            assert status == 200
            token = body.decode()
            try:
                status, body = request(url + "self", token=token)
                assert status == 200 and json.loads(body)["username"] == "admin"
            finally:
                req = urllib.request.Request(url + "logout", method="POST", headers={"Authorization": "Bearer " + token})
                with urllib.request.urlopen(req, timeout=5) as response:
                    assert response.status == 204
        elif command == "projection":
            for key in ("api-key", "github-token"):
                path = Path("/run/dependency-track-sync-credentials") / key
                assert path.read_text() == values[key]
                assert path.stat().st_uid == path.stat().st_gid == 0
                assert path.stat().st_mode & 0o777 == 0o400
        elif command == "probe":
            observed = json.loads(Path("/srv/state/dependency-track-evidence/unit-probe.json").read_text())
            assert observed["uid"] == observed["gid"] == 705
            assert observed["nixDaemonTrusted"] is False
            assert observed["hashes"] == {key: hashlib.sha256(values[key].encode()).hexdigest()
                                          for key in ("api-key", "github-token")}
        elif command == "acquisition-failed":
            state = json.loads(Path("/srv/state/dependency-track-evidence/state.json").read_text())
            assert state["refresh"]["operation"] == "discover"
            assert state["refresh"]["status"] == "failed-unknown"
            assert not state["refresh"]["targets"] and not state["targets"]
        elif command == "events":
            alerts = json.loads(k("get", "--raw",
                "/api/v1/namespaces/monitoring/services/http:alertmanager:9093/proxy/api/v2/alerts"))
            ids = []
            for alert in alerts:
                labels = alert["labels"]
                assert set(labels) == {"alertname", "source", "namespace", "severity", "host", "event_id"}
                assert labels == dict(alertname="DependencyTrackInventoryRefreshFailed", source="systemd",
                                      namespace="dependency-track", severity="warning", host="compute-1",
                                      event_id=labels["event_id"])
                assert str(uuid.UUID(labels["event_id"])) == labels["event_id"]
                starts = datetime.fromisoformat(alert["startsAt"].replace("Z", "+00:00"))
                ends = datetime.fromisoformat(alert["endsAt"].replace("Z", "+00:00"))
                assert 0 < (ends - starts).total_seconds() <= 600
                credentials = json.loads((root / "credential-history.json").read_text())
                assert all(value not in json.dumps(alert) for value in credentials)
                ids.append(labels["event_id"])
            print(json.dumps(sorted(ids)))
        elif command == "no-leaks":
            journal = subprocess.run(["journalctl", "--no-pager", "-o", "cat", "-u", "dependency-track-*"],
                                     check=True, capture_output=True).stdout
            history = json.loads((root / "credential-history.json").read_text())
            assert all(value.encode() not in journal for value in history)
        else:
            raise AssertionError("unknown fixture operation")
      '';
      test =
        (pkgs.testers.runNixOSTest {
          name = "dependency-track-systemd";
          requiredFeatures.kvm = true;
          globalTimeout = 90 * 60;
          nodes.machine = { config, pkgs, ... }: {
            # Re-evaluate the actual aspects against this VM, not resolved optional
            # NixOS submodule attrsets. K3s, all source units and controls stay real.
            imports = [
              kubernetes.nixos
              ({ config, pkgs, ... }: workload.nixos { inherit host config pkgs; })
            ];
            system.stateVersion = "26.05";
            networking.hostName = "compute-1";
            networking.firewall.enable = false;
            virtualisation = {
              cores = 4;
              memorySize = 6144;
              diskSize = 32768;
              restrictNetwork = false;
            };
            services.k3s.package = self.nixosConfigurations.compute-1.config.services.k3s.package;
            environment.systemPackages = [
              pkgs.python3
              pkgs.curl
              pkgs.jq
            ];
            systemd.tmpfiles.rules = [
              "d /srv/secrets 0700 root root -"
              "d /srv/state 0755 root root -"
              "f /srv/state/.homelab-state-root 0400 root root - dt-systemd-disposable-vm"
            ]
            ++ lib.mapAttrsToList (
              _: path: "d ${path.guestPath} ${path.mode} ${toString path.uid} ${toString path.gid} -"
            ) retainedPaths;
            systemd.services.dependency-track-sync.serviceConfig.ExecStartPre = lib.mkAfter [
              "${pkgs.python3}/bin/python3 -B ${probe}"
            ];
            environment.etc = {
              "dt-unit/bootstrap.json".source = manifest "dependency-track-unit-bootstrap.json" (
                volumes ++ bootstrap.applications.dependency-track.objects
              );
              "dt-unit/restore.json".source = manifest "dependency-track-unit-restore.json" (render "restore")
              .applications.dependency-track.objects;
              "dt-unit/alertmanager.json".source = alertmanager;
              "dt-unit/enforcer.json".source =
                manifest "dependency-track-unit-enforcer.json"
                  self.nixidyEnvs.${system}.prod-home.config.applications.network-policy.objects;
            };
          };
          testScript = ''
            import json
            import shlex

            k = "${self.nixosConfigurations.compute-1.config.services.k3s.package}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
            fixture = "${pkgs.python3}/bin/python3 -B ${fixture}"
            importer = "dependency-track-sync.service"
            policy = "dependency-track-access-policy.service"
            credentials = "dependency-track-sync-credentials.service"
            broker = "dependency-track-sync-api-tunnel.service"
            notifier = "dependency-track-sync-failure.service"
            evidence = "/srv/state/dependency-track-evidence"

            def f(operation):
                return machine.succeed(f"{fixture} {operation}")

            def stage(mode):
                f("stage " + mode)
                machine.succeed("systemctl start --wait kubernetes-runtime-secrets.service")

            def gate(admitted):
                machine.wait_until_succeeds(f"{fixture} gate {'true' if admitted else 'false'}", timeout=180)

            def run_failed():
                machine.succeed(f"systemctl reset-failed {importer} {policy} {credentials} {notifier}")
                machine.fail(f"systemctl start --wait {importer}")
                machine.wait_until_succeeds(f"test $(systemctl show -p ActiveState --value {notifier}) = inactive", timeout=90)
                assert machine.succeed(f"systemctl show -p Result --value {notifier}").strip() == "success"
                assert machine.succeed(f"systemctl show -p Result --value {importer}").strip() != "success"

            def events():
                return set(json.loads(f("events")))

            def fresh_event(previous):
                machine.wait_until_succeeds(
                    f"{fixture} events | ${pkgs.python3}/bin/python3 -c " + shlex.quote(
                        "import json,sys; assert len(set(json.load(sys.stdin)) - " + repr(previous) + ") == 1"),
                    timeout=90)
                return events()

            start_all()
            try:
                machine.wait_for_unit("multi-user.target")
                machine.succeed("systemctl stop dependency-track-sync.timer dependency-track-access-policy.timer")
                machine.succeed(f"systemctl stop {policy}")
                machine.wait_until_succeeds(f"{k} wait --for=condition=Ready nodes --all --timeout=10s", timeout=300)
                machine.succeed(f"{k} create namespace dependency-track")
                stage("bootstrap")
                machine.succeed(f"{k} apply -f /etc/dt-unit/enforcer.json")
                machine.wait_until_succeeds(f"{k} -n kube-system rollout status daemonset/kube-network-policies --timeout=10s", timeout=600)
                machine.succeed(f"{k} apply -f /etc/dt-unit/bootstrap.json -f /etc/dt-unit/alertmanager.json")
                machine.wait_until_succeeds(f"{k} -n monitoring wait --for=condition=Ready pod/unit-alertmanager --timeout=10s", timeout=600)
                machine.wait_until_succeeds(f"{k} -n dependency-track wait --for=condition=ContainersReady pod -l app.kubernetes.io/name=dependency-track-api --timeout=10s", timeout=900)
                machine.succeed(f"systemctl restart {broker}")
                machine.wait_for_open_port(1022)

                with subtest("source root bootstrap admits only the current Pod without an ingestor key"):
                    machine.fail(f"{k} -n dependency-track get secret dependency-track-sync")
                    gate(False)
                    machine.succeed(f"systemctl reset-failed {policy}; systemctl start --wait {policy}")
                    gate(True)
                    f("auth")
                    machine.succeed("test ! -e /run/dependency-track-access-policy/admin-password")

                with subtest("actual restore workload and new Pod UID require fresh admission"):
                    old = machine.succeed(f"{k} -n dependency-track get pod -l app.kubernetes.io/name=dependency-track-api -o jsonpath='{{.items[0].metadata.uid}}'")
                    old_name = machine.succeed(f"{k} -n dependency-track get pod -l app.kubernetes.io/name=dependency-track-api -o jsonpath='{{.items[0].metadata.name}}'").strip()
                    machine.succeed(f"{k} apply -f /etc/dt-unit/restore.json")
                    machine.succeed(f"{k} -n dependency-track wait --for=delete pod/{old_name} --timeout=180s")
                    machine.wait_until_succeeds(f"{k} -n dependency-track rollout status deployment/dependency-track-postgres --timeout=10s", timeout=300)
                    machine.wait_until_succeeds(f"{k} -n dependency-track wait --for=condition=ContainersReady pod -l app.kubernetes.io/name=dependency-track-api --timeout=10s", timeout=900)
                    new = machine.succeed(f"{k} -n dependency-track get pod -l app.kubernetes.io/name=dependency-track-api -o jsonpath='{{.items[0].metadata.uid}}'")
                    assert old != new
                    gate(False)
                    machine.succeed(f"systemctl restart {broker}")
                    machine.wait_for_open_port(1022)
                    machine.succeed(f"systemctl start --wait {policy}")
                    gate(True)

                with subtest("wrong and missing restored admin fail closed; real pre-start triggers OnFailure"):
                    stage("wrong-admin")
                    # Supply only throwaway acquisition values, never a GitHub credential.
                    machine.succeed(f"systemctl start --wait {credentials}")
                    before = events()
                    run_failed()
                    fresh_event(before)
                    gate(False)
                    f("auth")
                    machine.succeed(f"test ! -e {evidence}/state.json; test ! -e {evidence}/unit-probe.json")
                    stage("missing-admin")
                    machine.succeed(f"systemctl reset-failed {policy}")
                    machine.fail(f"systemctl start --wait {policy}")
                    gate(False)
                    f("auth")
                    stage("valid")
                    machine.succeed(f"systemctl reset-failed {policy}; systemctl start --wait {policy}")
                    gate(True)
                    f("auth")

                with subtest("actual UID705 sandbox reads Nix daemon untrusted and refuses invalid acquisition"):
                    before = events()
                    run_failed()
                    fresh_event(before)
                    f("projection")
                    f("probe")
                    f("acquisition-failed")
                    machine.fail("runuser -u dependency-track-sync -- test -r /etc/rancher/k3s/k3s.yaml")
                    machine.fail("runuser -u dependency-track-sync -- test -r /run/dt-unit-fixture/secrets.json")
                    machine.succeed(f"test ! -e /run/credentials/{importer}; test ! -e /run/dependency-track-sync-failure")

                with subtest("LoadCredential reloads projected rotation and missing key refuses stale acquisition"):
                    previous = machine.succeed(f"cat {evidence}/unit-probe.json")
                    stage("rotate")
                    before = events()
                    run_failed()
                    fresh_event(before)
                    f("projection")
                    f("probe")
                    assert json.loads(previous)["hashes"] != json.loads(machine.succeed(f"cat {evidence}/unit-probe.json"))["hashes"]
                    previous = machine.succeed(f"cat {evidence}/unit-probe.json")
                    state = machine.succeed(f"sha256sum {evidence}/state.json")
                    stage("missing-key")
                    before = events()
                    run_failed()
                    fresh_event(before)
                    assert previous == machine.succeed(f"cat {evidence}/unit-probe.json")
                    assert state == machine.succeed(f"sha256sum {evidence}/state.json")

                with subtest("stop clears real unit credentials and processes; normal timers invoke source lifecycle"):
                    stage("valid")
                    machine.succeed(f"touch {evidence}/unit-probe-hold; chown 705:705 {evidence}/unit-probe-hold; rm {evidence}/unit-probe.json")
                    machine.succeed(f"systemctl reset-failed {importer} {credentials}; systemctl start --no-block {importer}")
                    machine.wait_until_succeeds(f"test -s {evidence}/unit-probe.json", timeout=180)
                    pid = json.loads(machine.succeed(f"cat {evidence}/unit-probe.json"))["pid"]
                    machine.succeed(f"systemctl stop {importer}")
                    machine.fail(f"kill -0 {pid}")
                    machine.succeed(f"rm {evidence}/unit-probe-hold; test ! -e /run/credentials/{importer}")
                    machine.succeed(f"systemctl reset-failed {importer} {policy}; systemctl start dependency-track-sync.timer dependency-track-access-policy.timer")
                    machine.wait_until_succeeds("test $(systemctl show -p LastTriggerUSecMonotonic --value dependency-track-sync.timer) -gt 0", timeout=180)
                    machine.wait_until_succeeds("test $(systemctl show -p LastTriggerUSecMonotonic --value dependency-track-access-policy.timer) -gt 0", timeout=180)
                    machine.wait_until_succeeds(f"test $(systemctl show -p ActiveState --value {importer}) = failed", timeout=180)
                    f("probe")
                    f("acquisition-failed")
                    f("no-leaks")
                    machine.succeed("systemctl stop dependency-track-sync.timer dependency-track-access-policy.timer")
                    machine.succeed(f"systemctl stop {importer} {policy} {credentials} {broker} {notifier}")
                    machine.succeed("test ! -e /run/dependency-track-sync-api-tunnel; test ! -e /run/dependency-track-access-policy; test ! -e /run/dependency-track-sync-failure")
                    machine.fail("ss -H -ltn 'sport = :1022' | ${pkgs.gnugrep}/bin/grep .")
            finally:
                for unit in (importer, policy, credentials, broker, notifier):
                    print(json.dumps({"unit": unit, "state": machine.execute(
                        "systemctl show --property=Id,Result,ExecMainStatus,ExecStartPre " + unit)[1]}))
                # Every resource belongs to this VM. No shared daemon/context/host cleanup.
                machine.execute("systemctl stop dependency-track-sync.timer dependency-track-access-policy.timer dependency-track-sync.service dependency-track-access-policy.service dependency-track-sync-api-tunnel.service dependency-track-sync-credentials.service dependency-track-sync-failure.service kubernetes-runtime-secrets.path")
                machine.execute(f"{k} delete namespace dependency-track monitoring --wait=true --timeout=180s")
                machine.execute("systemctl stop kubernetes-runtime-secrets.service k3s.service")
                machine.execute("rm -rf /run/dt-unit-fixture /run/dependency-track-sync-credentials /srv/secrets /srv/state/dependency-track-api /srv/state/dependency-track-postgres /srv/state/dependency-track-evidence")
                machine.shutdown()
          '';
        }).overrideTestDerivation
          (_: {
            # Like existing real-K3s checks: pull stock pinned images and exercise a
            # rejected GitHub API acquisition. No real credential or provider delivery.
            __noChroot = true;
          });
    in
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        dependency-track-systemd = test // {
          meta = test.meta // {
            hestia.group = "${system}-dependency-track-systemd";
          };
        };
      };
    };
}
