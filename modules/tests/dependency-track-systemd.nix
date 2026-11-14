# The default check is secretless. Standalone checks.x86_64-linux.
# dependency-track-systemd.driver also accepts HOMELAB_DT_SYSTEMD_TOKEN_FILE:
# an absolute private regular token-file PATH, never a token-valued input.
# Run its bin/nixos-test-driver --output_directory PRIVATE_EXISTING_DIRECTORY
# with private TMPDIR and no --keep-machine-state. The caller owns the input.
# Live imports use a disposable security-branch canary, not main/deployed authority.
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
            den.hosts.x86_64-linux.compute-1.settings.workloads.dependency-track-sync = {
              apiUrl = "http://127.0.0.1:1022";
              branch = "security/software-vulnerability-management";
              # Use a 30-second fixture schedule; leave production defaults unchanged.
              onCalendar = "*-*-* *:*:00/30";
              targetIds = [
                "3ca171bb4d06a0d2584c981f"
                "cc64e08c1afb4776b4d587d4"
              ];
            };
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
        import stat
        import subprocess
        import sys
        import time

        sys.path.insert(0, "${syncPackage}/lib/dependency-track-sync")
        import dependency_track_sync as sync

        assert os.getuid() == os.getgid() == 705
        assert "NoNewPrivs:\t1" in Path("/proc/self/status").read_text()
        state = Path("/srv/state/dependency-track-evidence")
        credentials = Path(os.environ["CREDENTIALS_DIRECTORY"])
        # systemd 261 write_credential() grants UID705 an ACL, not group access:
        # https://github.com/systemd/systemd/blob/v261.2/src/core/exec-credential.c
        # The POSIX ACL mask occupies st_mode's group bits (typically 0440).
        # Prove the actual ACL/consumer/mount boundary, not incidental mode alone.
        def metadata(path):
            info = path.lstat()
            acl = subprocess.run(["${pkgs.acl}/bin/getfacl", "-cpnE", str(path)],
                                 check=True, capture_output=True, text=True, timeout=10).stdout
            return {"mode": oct(stat.S_IMODE(info.st_mode)), "uid": info.st_uid, "gid": info.st_gid,
                    "regular": stat.S_ISREG(info.st_mode), "directory": stat.S_ISDIR(info.st_mode),
                    "acl": sorted(line for line in acl.splitlines() if line)}

        mounts = []
        for line in Path("/proc/self/mountinfo").read_text().splitlines():
            fields = line.split()
            if fields[4] == str(credentials):
                split = fields.index("-")
                mounts.append({"target": fields[4], "options": fields[5].split(","),
                               "type": fields[split + 1], "superOptions": fields[split + 3].split(",")})
        credential_metadata = {"directory": metadata(credentials), "mounts": mounts,
                               "files": {key: metadata(credentials / key) for key in ("api-key", "github-token")}}
        # Safe diagnostics precede every credential assertion, including on failure.
        print(json.dumps({"systemdCredentialBoundary": credential_metadata}), flush=True)
        assert len(mounts) == 1 and mounts[0]["type"] in ("tmpfs", "ramfs")
        assert "ro" in mounts[0]["options"]
        hashes = {}
        for key, info in credential_metadata["files"].items():
            path = credentials / key
            assert info["regular"]
            hashes[key] = hashlib.sha256(sync.credential(path).encode()).hexdigest()
            assert not os.access(path, os.W_OK)
        rejected = {}
        for name, gid, acl in (
                ("owning-group", 705, ["group::r--", "other::---", "user::r--"]),
                ("extra-reader", 0, ["group::---", "mask::r--", "other::---",
                                     "user:705:r--", "user:706:r--", "user::r--"])):
            path = Path("/run/dt-unit-credential-boundary") / name
            info = metadata(path)
            print(json.dumps({"readableNonCredentialBoundary": {name: info}}), flush=True)
            assert info["regular"] and info["uid"] == 0 and info["gid"] == gid
            assert info["mode"] == "0o440" and info["acl"] == sorted(acl)
            # Actual UID705 kernel open succeeds; the shared getter must still
            # reject group access and an ACL that admits another named reader.
            path.read_bytes()
            try:
                sync.credential(path)
            except ValueError:
                pass
            else:
                raise AssertionError("credential getter admitted an additional reader")
            rejected[name] = info
        credential_metadata["rejectedReadableFiles"] = rejected
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
                  "nixDaemonTrusted": ping["trusted"], "pid": os.getpid(),
                  "credentialBoundary": credential_metadata}
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

        sys.path.insert(0, "${syncPackage}/lib/dependency-track-sync")
        import dependency_track_sync as sync

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
            if mode == "live":
                values["github-token"] = sync.credential(root / "github-token")
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
        if command == "credential-boundary":
            boundary = Path("/run/dt-unit-credential-boundary")
            boundary.mkdir(mode=0o711)
            boundary.chmod(0o711)
            for name, gid in (("owning-group", 705), ("extra-reader", 0)):
                path = boundary / name
                path.write_text("nonsecret credential boundary fixture")
                os.chown(path, 0, gid)
                path.chmod(0o440)
                subprocess.run(["${pkgs.acl}/bin/setfacl", "-b", str(path)], check=True)
            subprocess.run(["${pkgs.acl}/bin/setfacl", "--set",
                            "u::r--,u:705:r--,u:706:r--,g::---,m::r--,o::---",
                            str(boundary / "extra-reader")], check=True)
        elif command == "stage":
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
        elif command == "enroll":
            stock = sync.Client("http://127.0.0.1:1022", anonymous=True)
            bearer = stock.request("POST", "user/login",
                                  {"username": "admin", "password": values["admin"]}, form=True, text=True)
            bearer_file = root / "admin-bearer"
            bearer_file.write_text(bearer)
            bearer_file.chmod(0o400)
            history_file = root / "credential-history.json"
            history_file.write_text(json.dumps(json.loads(history_file.read_text()) + [bearer]))
            admin = sync.Client(stock.url, bearer_file, bearer=True)
            try:
                team = admin.request("PUT", "team", {"name": "systemd-canary-ingestor"})
                permissions = ["BOM_UPLOAD", "PORTFOLIO_MANAGEMENT", "VIEW_PORTFOLIO"]
                for permission in permissions:
                    admin.request("POST", "permission/" + permission + "/team/" + team["uuid"])
                assigned = admin.request("GET", "team/" + team["uuid"])
                assert sorted(item["name"] for item in assigned["permissions"]) == permissions
                values["api-key"] = admin.request("PUT", "team/" + team["uuid"] + "/key")["key"]
                history_file.write_text(json.dumps(json.loads(history_file.read_text()) + [values["api-key"]]))
                secret_file.write_text(json.dumps(values))
                key_file = root / "enrolled-key"
                key_file.write_text(values["api-key"])
                key_file.chmod(0o400)
                restricted = sync.Client(stock.url, key_file)
                try:
                    restricted.request("GET", "team")
                except sync.ApiError as error:
                    assert error.status in (401, 403)
                else:
                    raise AssertionError("ingestor has administrative access")
                (root / "enrollment.json").write_text(json.dumps({"permissions": permissions,
                                                                "restrictedAdminRefused": True}))
            finally:
                try:
                    admin.request("POST", "user/logout", expected_status=204)
                finally:
                    bearer_file.unlink()
        elif command == "live-readback":
            state_directory = Path("/srv/state/dependency-track-evidence")
            database = sync.load(state_directory / "state.json")
            policy = {"repository": "dvicory/homelab", "branch": "security/software-vulnerability-management"}
            wanted = {"3ca171bb4d06a0d2584c981f": "nix", "cc64e08c1afb4776b4d587d4": "oci"}
            assert database["sourcePolicy"] == policy
            assert database["selectionPolicy"] == {"states": [], "targetIds": sorted(wanted)}
            refresh = database["refresh"]
            assert refresh["status"] == refresh["operation"] == "complete"
            selected = {key: item for key, item in database["expected"].items() if item["selected"]}
            assert {item["source"]["id"] for item in selected.values()} == set(wanted)
            assert set(database["targets"]) == set(refresh["targets"]) == set(selected)
            stock = sync.Client("http://127.0.0.1:1022", root / "enrolled-key")

            def inside(value):
                path = Path(value)
                assert not path.is_symlink()
                assert path.resolve(strict=True).is_relative_to(state_directory.resolve())
                return path

            def properties(project):
                return {item["propertyName"]: item["propertyValue"]
                        for item in stock.request("GET", "project/" + project + "/property")
                        if item["groupName"] == sync.GROUP}

            def pages(path):
                seen = {}
                for page in range(1, 501):
                    items = stock.request("GET", path + "?" + urllib.parse.urlencode(
                        {"pageSize": 100, "pageNumber": page}))
                    assert isinstance(items, list) and len(items) <= 100
                    for item in items:
                        identifier = str(uuid.UUID(item["uuid"]))
                        assert identifier not in seen
                        seen[identifier] = item
                    if len(items) < 100:
                        return seen
                raise AssertionError("API pagination bound exceeded")

            summaries = {}
            project_ids = set()
            source_identity = None
            for target, expected in selected.items():
                record = database["targets"][target]
                planned = expected["source"]
                declaration = record["source"]
                for key in ("id", "kind", "system", "target", "source", "pointer", "state",
                            "location", "update", "image", "resolvedImage", "ociPlatform"):
                    assert declaration.get(key) == planned.get(key)
                assert declaration["kind"] == wanted[declaration["id"]]
                assert target == sync.target_key(declaration)
                assert expected["coverage"] == "complete-inventory"
                assert refresh["targets"][target]["status"] == "complete"
                assert record["lastAttempt"]["status"] == "complete"
                assert not record.get("pending") and not record.get("retiring")
                assert record["statusPublishFailed"] is False
                assert record["selection"]["selected"] is True
                current = record["current"]
                required = {"native", "language"} if declaration["kind"] == "nix" else {"image"}
                assert required <= set(current["projects"])
                assert set(current["complete"]) == set(current["projects"]) == set(current["hashes"])
                acquisition = record["acquisition"]
                evidence = inside(acquisition["evidence"])
                receipt = sync.load(evidence / "source.json")
                run = receipt["run"]
                producer = sync.security_artifacts.trusted_run(run, policy["repository"], policy["branch"])
                assert receipt["producer"] == producer and run["status"] == "completed"
                assert acquisition["run"] == refresh["run"] == run["id"]
                assert acquisition["sha"] == run["head_sha"]
                assert {key: acquisition[key] for key in policy} == policy
                identity = {key: run[key] for key in
                            ("id", "head_sha", "head_branch", "path", "event", "conclusion", "updated_at")}
                assert source_identity is None or source_identity == identity
                source_identity = identity
                artifact = acquisition["artifact"]
                assert sync.load(evidence / (target + "-artifact.json")) == artifact
                assert artifact["workflow_run"]["id"] == run["id"]
                assert artifact["workflow_run"]["head_sha"] == run["head_sha"]
                assert artifact["workflow_run"]["head_branch"] == policy["branch"]
                for item in (receipt["planArtifact"], artifact):
                    archive_zip = inside(state_directory / "artifacts" / (str(item["id"]) + ".zip"))
                    assert item["digest"] == "sha256:" + sync.security_artifacts.digest(archive_zip)
                    assert item["size_in_bytes"] == archive_zip.stat().st_size
                for archive in record["receipts"]:
                    archive = inside(archive)
                    manifest = sync.load(archive / "complete.json")
                    sync.security_artifacts.verify(archive, manifest["inventoryKey"], producer)
                    assert sync.security_artifacts.digest(archive / "complete.json") == archive.name
                archive = inside(current["archive"])
                manifest = sync.load(archive / "complete.json")
                description = sync.describe(declaration, manifest, archive)
                assert all(current[key] == description[key] for key in
                           ("revision", "revisionId", "hashes", "contentHashes"))
                assert sync.load(archive / "provenance.json") == declaration
                collection = record["collection"]
                stock.project(sync.project_name(declaration), "collection", collection=True, cached=collection,
                              identity=sync.project_identity(declaration))
                assert stock.request("GET", "project/" + collection)["active"] is True
                project_ids.add(collection)
                collection_properties = properties(collection)
                assert collection_properties["collection_status"] == "complete"
                assert collection_properties["selection_status"] == "selected"
                published_run = json.loads(collection_properties["source_run"])
                assert published_run["run"] == run["id"] and published_run["sha"] == run["head_sha"]
                component_counts = {}
                native_components = {}
                for stream, project in current["projects"].items():
                    stock.project(sync.project_name(declaration, current["revisionId"], stream), "inventory",
                                  collection, cached=project,
                                  identity=sync.project_identity(declaration, current["revisionId"], stream))
                    leaf = stock.request("GET", "project/" + project)
                    assert leaf["active"] is True and leaf["isLatest"] is True
                    project_ids.add(project)
                    metadata = properties(project)
                    for key, value in {"deployment": "unobserved", "source_scope": declaration["state"],
                                       "inventory_key": manifest["inventoryKey"],
                                       "import_sha256": current["hashes"][stream],
                                       "archive_seal_sha256": archive.name}.items():
                        assert metadata[key] == value
                    components = pages("component/project/" + project)
                    if stream in ("native", "image"):
                        witness = sync.load(archive / description["streams"][stream])["components"][0]
                        assert any(item.get("bomRef") == witness["bom-ref"]
                                   and item["name"] == witness["name"]
                                   and item.get("version") == witness.get("version")
                                   for item in components.values())
                    component_counts[stream] = len(components)
                    if stream == "native":
                        native_components = components
                origin_summary = None
                if declaration["kind"] == "nix":
                    assert record["origins"]["lastAttempt"]["status"] == "complete"
                    origin = record["origins"]["current"]
                    directory = inside(origin["directory"])
                    report = sync.load(directory / "origins.json")
                    assert origin["project"] == current["projects"]["native"]
                    assert origin["originalArchive"] == current["archive"]
                    assert origin["inventoryKey"] == manifest["inventoryKey"]
                    assert origin["source"]["revision"] == run["head_sha"]
                    assert origin["source"]["flake"] == "github:dvicory/homelab/" + run["head_sha"]
                    assert report["root"] == {key: declaration[key] for key in ("drvPath", "outPath")}
                    assert report["source"] == origin["source"]
                    assert sync.security_artifacts.digest(directory / "origins.json") == origin["reportSha256"]
                    assert sync.security_artifacts.digest(directory / "native-origins.cdx.json") == origin["bomSha256"]
                    metadata = properties(origin["project"])
                    assert metadata["origin_report_sha256"] == origin["reportSha256"]
                    assert metadata["origin_bom_sha256"] == origin["bomSha256"]
                    assert json.loads(metadata["origin_source"]) == origin["source"]
                    # In addition to the full origin receipt, read one actual
                    # attributed component's properties and source links back
                    # through the stock API (not merely our local journal).
                    enriched = sync.load(directory / "native-origins.cdx.json")
                    for component in enriched["components"]:
                        wanted_properties = {(item["name"].split(":", 1)[1], item["value"])
                                             for item in component.get("properties", [])
                                             if item["name"].startswith("homelab:")}
                        if not any(name == "declarations" for name, value in wanted_properties):
                            continue
                        expected_links = {(item["url"], item.get("comment")) for item in
                                          component.get("externalReferences", [])
                                          if item.get("comment", "").startswith("homelab:origin:v1 ")}
                        if not expected_links:
                            continue
                        matches = [item for item in native_components.values()
                                   if item.get("bomRef") == component["bom-ref"]]
                        assert len(matches) == 1
                        component_id = matches[0]["uuid"]
                        actual_properties = {(item["propertyName"], item["propertyValue"])
                                             for item in stock.request("GET", "component/" + component_id + "/property")
                                             if item.get("groupName") == "homelab"}
                        assert actual_properties == wanted_properties
                        detail = stock.request("GET", "component/" + component_id)
                        actual_links = {(item["url"], item.get("comment")) for item in
                                        detail.get("externalReferences", [])}
                        assert expected_links <= actual_links
                        break
                    else:
                        raise AssertionError("no attributed native component read back")
                    origin_summary = {"counts": report["counts"], "completeCoverage": report["coverage"]["complete"],
                                      "sourceRevision": origin["source"]["revision"],
                                      "attributedComponentReadbackCount": 1, "component": component_id}
                else:
                    assert record["origins"]["lastAttempt"]["status"] == "unsupported"
                summaries[declaration["id"]] = {"target": target, "kind": declaration["kind"],
                    "collection": collection, "projects": current["projects"], "components": component_counts,
                    "artifactId": artifact["id"], "inventoryKey": manifest["inventoryKey"], "origins": origin_summary}
            projects = pages("project")
            assert set(projects) == project_ids
            unit = subprocess.run(["systemctl", "show", "dependency-track-sync.service",
                "--property=Id,User,Group,InvocationID,Result,ExecMainStatus,NoNewPrivileges,ProtectSystem,ProtectHome,PrivateTmp,MemoryMax,CPUQuotaPerSecUSec"],
                check=True, capture_output=True, text=True, timeout=10).stdout
            unit = dict(line.split("=", 1) for line in unit.splitlines())
            assert unit["Result"] == "success" and unit["ExecMainStatus"] == "0"
            observation = {"scope": "isolated-security-branch-canary", "deployment": "unobserved",
                           "sourcePolicy": policy, "source": source_identity, "targets": summaries,
                           "enrollment": sync.load(root / "enrollment.json"), "unit": unit,
                           "journalSha256": sync.security_artifacts.digest(state_directory / "state.json"),
                           "credentialBoundary": sync.load(state_directory / "unit-probe.json")["credentialBoundary"]}
            (state_directory / "systemd-live-observation.json").write_text(json.dumps(observation))
            print(json.dumps(observation))
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
            assert set(observed["credentialBoundary"]["rejectedReadableFiles"]) == {"owning-group", "extra-reader"}
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
            # Start source timers only after fixture Secrets and Alertmanager exist.
            systemd.timers = {
              dependency-track-sync.wantedBy = lib.mkForce [ ];
              dependency-track-access-policy.wantedBy = lib.mkForce [ ];
            };
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
            import os
            from pathlib import Path
            import shlex
            import stat
            import tempfile
            import uuid

            k = "${self.nixosConfigurations.compute-1.config.services.k3s.package}/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
            fixture = "${pkgs.python3}/bin/python3 -B ${fixture}"
            importer = "dependency-track-sync.service"
            policy = "dependency-track-access-policy.service"
            credentials = "dependency-track-sync-credentials.service"
            broker = "dependency-track-sync-api-tunnel.service"
            notifier = "dependency-track-sync-failure.service"
            evidence = "/srv/state/dependency-track-evidence"
            # Read only this explicit runtime PATH. No gh profile or inherited token
            # values are consulted. Nix builds never supply the variable.
            token_file = os.environ.pop("HOMELAB_DT_SYSTEMD_TOKEN_FILE", None)

            def copy_live_token():
                assert token_file is not None
                path = Path(token_file)
                assert path.is_absolute() and not path.resolve().is_relative_to("/nix/store")
                descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(descriptor, "rb") as source:
                    info = os.fstat(source.fileno())
                    assert stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                    assert stat.S_IMODE(info.st_mode) in (0o400, 0o600)
                    assert 0 < info.st_size <= 65536
                    value = source.read(65537)
                    assert 0 < len(value) <= 65536 and len(value) == info.st_size
                    text = value.decode().strip()
                    assert text and "\n" not in text and "\r" not in text
                    with tempfile.TemporaryDirectory(prefix="dt-unit-runtime-") as directory:
                        snapshot = Path(directory) / "github-token"
                        snapshot.write_bytes(text.encode())
                        snapshot.chmod(0o400)
                        # This driver transport copies a private file through a
                        # temporary shared directory, never shell echo/base64/argv.
                        machine.copy_from_host(str(snapshot), "/run/dt-unit-fixture/github-token")

            def f(operation):
                return machine.succeed(f"{fixture} {operation}")

            def stage(mode):
                f("stage " + mode)
                machine.succeed("systemctl start --wait kubernetes-runtime-secrets.service")

            def gate(admitted):
                machine.wait_until_succeeds(f"{fixture} gate {'true' if admitted else 'false'}", timeout=180)

            def reset_failed(*units):
                for unit in units:
                    if machine.succeed(f"systemctl show -p ActiveState --value {unit}").strip() == "failed":
                        machine.succeed(f"systemctl reset-failed {unit}")

            def run_failed():
                reset_failed(importer, policy, credentials, notifier)
                machine.fail(f"systemctl start --wait {importer}")
                machine.wait_until_succeeds(f"test $(systemctl show -p ActiveState --value {notifier}) = inactive", timeout=90)
                assert machine.succeed(f"systemctl show -p Result --value {notifier}").strip() == "success"
                assert machine.succeed(f"systemctl show -p Result --value {importer}").strip() != "success"

            def events():
                return set(json.loads(f("events")))

            def fresh_event(previous, timeout=90):
                machine.wait_until_succeeds(
                    f"{fixture} events | ${pkgs.python3}/bin/python3 -c " + shlex.quote(
                        "import json,sys; assert len(set(json.load(sys.stdin)) - " + repr(previous) + ") == 1"),
                    timeout=timeout)
                return events()

            start_all()
            try:
                machine.wait_for_unit("multi-user.target")
                machine.succeed("systemctl stop dependency-track-sync.timer dependency-track-access-policy.timer")
                machine.succeed(f"systemctl stop {policy}")
                machine.wait_until_succeeds(f"{k} wait --for=condition=Ready nodes --all --timeout=10s", timeout=300)
                machine.succeed(f"{k} create namespace dependency-track")
                stage("bootstrap")
                f("credential-boundary")
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
                    reset_failed(policy)
                    machine.succeed(f"systemctl start --wait {policy}")
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
                    reset_failed(policy)
                    machine.fail(f"systemctl start --wait {policy}")
                    gate(False)
                    f("auth")
                    stage("valid")
                    reset_failed(policy)
                    machine.succeed(f"systemctl start --wait {policy}")
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

                with subtest("stop clears real unit credentials and processes; timers invoke fresh source lifecycle"):
                    stage("valid")
                    machine.succeed(f"touch {evidence}/unit-probe-hold; chown 705:705 {evidence}/unit-probe-hold; rm {evidence}/unit-probe.json")
                    reset_failed(importer, credentials)
                    machine.succeed(f"systemctl start --no-block {importer}")
                    machine.wait_until_succeeds(f"test -s {evidence}/unit-probe.json", timeout=180)
                    pid = json.loads(machine.succeed(f"cat {evidence}/unit-probe.json"))["pid"]
                    # Root observation joins the held probe's actual mount namespace;
                    # no source service setting changes and no secret bytes are read.
                    for uid, gid in ((65534, 65534), (65534, 705)):
                        observer = (
                            f"${pkgs.util-linux}/bin/nsenter --mount=/proc/{pid}/ns/mnt -- "
                            f"${pkgs.util-linux}/bin/setpriv --reuid={uid} --regid={gid} --clear-groups -- ")
                        assert machine.succeed(observer + "${pkgs.coreutils}/bin/id -u").strip() == str(uid)
                        for key in ("api-key", "github-token"):
                            machine.fail(observer + f"${pkgs.coreutils}/bin/test -r /run/credentials/{importer}/{key}")
                    machine.succeed(f"systemctl stop {importer}")
                    machine.fail(f"kill -0 {pid}")
                    machine.succeed(f"rm {evidence}/unit-probe-hold; test ! -e /run/credentials/{importer}")
                    # A killed pre-start also invokes OnFailure; settle it before
                    # capturing the timer's event baseline, so it cannot pass stale.
                    machine.wait_until_succeeds(f"test $(systemctl show -p ActiveState --value {notifier}) = inactive", timeout=90)
                    assert machine.succeed(f"systemctl show -p Result --value {notifier}").strip() == "success"
                    reset_failed(importer, policy)
                    policy_invocation = machine.succeed(f"systemctl show -p InvocationID --value {policy}").strip()
                    # Observe this timer alone: the importer's root pre-start
                    # must not masquerade as a policy-timer invocation.
                    machine.succeed("systemctl start dependency-track-access-policy.timer")
                    machine.wait_until_succeeds(
                        f'test "$(systemctl show -p InvocationID --value {policy})" != {shlex.quote(policy_invocation)}', timeout=180)
                    machine.wait_until_succeeds(f"test $(systemctl show -p ActiveState --value {policy}) = inactive", timeout=180)
                    assert machine.succeed(f"systemctl show -p Result --value {policy}").strip() == "success"
                    assert uuid.UUID(machine.succeed(f"systemctl show -p InvocationID --value {policy}").strip()).hex != policy_invocation
                    machine.succeed("systemctl stop dependency-track-access-policy.timer")
                    before = events()
                    importer_invocation = machine.succeed(f"systemctl show -p InvocationID --value {importer}").strip()
                    machine.succeed(f"rm {evidence}/unit-probe.json; systemctl start dependency-track-sync.timer")
                    # No manual service start: a new semantic OnFailure event,
                    # invocation and UID705 probe must all come from the timer.
                    fresh_event(before, timeout=180)
                    machine.succeed("systemctl stop dependency-track-sync.timer")
                    assert uuid.UUID(machine.succeed(f"systemctl show -p InvocationID --value {importer}").strip()).hex != importer_invocation
                    assert machine.succeed(f"systemctl show -p ActiveState --value {importer}").strip() == "failed"
                    machine.wait_until_succeeds(f"test $(systemctl show -p ActiveState --value {notifier}) = inactive", timeout=90)
                    assert machine.succeed(f"systemctl show -p Result --value {notifier}").strip() == "success"
                    f("probe")
                    f("acquisition-failed")
                    f("no-leaks")
                    machine.succeed("systemctl stop dependency-track-sync.timer dependency-track-access-policy.timer")

                if token_file is not None:
                    with subtest("actual source systemd unit completes restricted two-target security canary refresh"):
                        copy_live_token()
                        machine.fail("runuser -u dependency-track-sync -- test -r /run/dt-unit-fixture/github-token")
                        f("enroll")
                        stage("live")
                        reset_failed(importer, policy, credentials, notifier)
                        machine.succeed(f"systemctl start --wait {importer}", timeout=2 * 60 * 60 + 180)
                        gate(True)
                        f("projection")
                        f("probe")
                        f("live-readback")
                        f("no-leaks")
                        machine.succeed(f"test ! -e /run/credentials/{importer}")
                        machine.copy_from_machine(f"{evidence}/systemd-live-observation.json")
                else:
                    print("Secretless check: live success requires explicit runtime token-file PATH.")

                with subtest("all source runtime units and listeners stop"):
                    machine.succeed(f"systemctl stop {importer} {policy} {credentials} {broker} {notifier}")
                    machine.succeed("test ! -e /run/dependency-track-sync-api-tunnel; test ! -e /run/dependency-track-access-policy; test ! -e /run/dependency-track-sync-failure")
                    machine.fail("ss -H -ltn 'sport = :1022' | ${pkgs.gnugrep}/bin/grep .")
            finally:
                for unit in (importer, policy, credentials, broker, notifier):
                    print(json.dumps({"unit": unit, "state": machine.execute(
                        "systemctl show --property=Id,Result,ExecMainStatus,ExecStartPre " + unit)[1]}))
                leak_status = 0
                if machine.execute("test -f /run/dt-unit-fixture/credential-history.json")[0] == 0:
                    leak_status = machine.execute(f"{fixture} no-leaks")[0]
                # Every resource belongs to this VM. No shared daemon/context/host cleanup.
                machine.execute("systemctl stop dependency-track-sync.timer dependency-track-access-policy.timer dependency-track-sync.service dependency-track-access-policy.service dependency-track-sync-api-tunnel.service dependency-track-sync-credentials.service dependency-track-sync-failure.service kubernetes-runtime-secrets.path")
                machine.execute(f"{k} delete namespace dependency-track monitoring --wait=true --timeout=180s")
                machine.execute("systemctl stop kubernetes-runtime-secrets.service k3s.service")
                machine.execute("rm -rf /run/dt-unit-fixture /run/dt-unit-credential-boundary /run/dependency-track-sync-credentials /srv/secrets /srv/state/dependency-track-api /srv/state/dependency-track-postgres /srv/state/dependency-track-evidence")
                machine.shutdown()
                assert leak_status == 0, "unit journal contains a private credential"
          '';
        }).overrideTestDerivation
          (_: {
            # The builder path exercises only a rejected GitHub acquisition with
            # throwaway credentials. Live credentials enter the standalone driver
            # after building, never this derivation or its environment.
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
