"""Real CLI/disk boundary: rejected or missing inputs cannot erase current/history.

No API emulator, credentials grant, downloaded execution or stock-runtime claim.
Parent separately qualifies successful imports/transitions against stock DT.
"""
import copy
from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

import dependency_track_sync as sync
import security_artifacts
import homelab_origins
import homelab_origin_bom


def regression():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        state = root / "state"
        state.mkdir()
        incoming = root / "inventory"
        incoming.mkdir()
        key = root / "key"
        key.write_text("test-only-never-transmitted")
        key.chmod(0o600)
        provenance = {"id": "a" * 24, "inventoryKey": "b" * 24, "kind": "oci", "system": "x86_64-linux",
                      "state": "referenced", "source": "generated/manifests/test/workload.yaml", "pointer": "/spec/image",
                      "location": "generated/manifests/test/workload.yaml", "update": "owning image declaration",
                      "resolvedImage": "example.invalid/test@sha256:" + "c" * 64, "ociPlatform": "linux/amd64"}
        # Changing the image behind one manifest reference must not rename its collection.
        renamed_image = dict(provenance, resolvedImage="example.invalid/renamed@sha256:" + "d" * 64)
        assert sync.project_name(renamed_image) == sync.project_name(provenance)
        sync.save(incoming / "provenance.json", provenance)
        document = {"bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
                    "serialNumber": "urn:uuid:11111111-1111-4111-8111-111111111111",
                    "metadata": {"timestamp": "2026-01-01T00:00:00Z"},
                    "components": [], "dependencies": []}
        sync.save(incoming / "language.cdx.json", document)
        security_artifacts.seal(incoming, provenance["inventoryKey"])
        archived, _, manifest, description = sync.archive_inventory(incoming, state)
        original_archive = {path.name: path.read_bytes() for path in archived.iterdir()}
        document["serialNumber"] = "urn:uuid:22222222-2222-4222-8222-222222222222"
        document["metadata"]["timestamp"] = "2026-01-02T00:00:00Z"
        (incoming / "language.cdx.json").write_text(json.dumps(document, separators=(",", ":")))
        security_artifacts.seal(incoming, provenance["inventoryKey"])
        _, _, _, recollected = sync.archive_inventory(incoming, state)
        assert recollected["hashes"] != description["hashes"]
        assert recollected["contentHashes"] == description["contentHashes"]
        document["components"] = [{"type": "library", "name": "changed-software", "version": "2"}]
        sync.save(incoming / "language.cdx.json", document)
        security_artifacts.seal(incoming, provenance["inventoryKey"])
        _, _, _, changed = sync.archive_inventory(incoming, state)
        assert changed["contentHashes"] != description["contentHashes"]
        current = {"revision": description["revision"], "projects": {"image": "retained-current"}, "archive": str(archived)}
        history = [{"revision": ["older-image", "linux/amd64"], "projects": {"image": "retained-history"}}]
        target = description["target"]
        database = {"schema": 1, "apiOrigin": "http://127.0.0.1:1", "targets": {
            target: {"input": str(incoming), "current": current, "history": history,
                     "lastSuccess": sync.now(), "lastAttempt": {"status": "complete"}}}}
        sync.save(state / "state.json", database)
        command = [sys.executable, "-B", str(Path(sync.__file__)), "sync", "--api-url", database["apiOrigin"],
                   "--api-key-file", str(key), "--inventory", str(incoming), "--state-dir", str(state)]
        # A hash mismatch must fail before contacting even an unavailable API.
        (incoming / "language.cdx.json").write_text("tampered")
        rejected = subprocess.run(command, capture_output=True, text=True)
        assert rejected.returncode == 1
        after = sync.load(state / "state.json")
        assert after["targets"][target]["current"] == current
        assert after["targets"][target]["history"] == history
        assert after["targets"][target]["lastAttempt"]["status"] == "failed-unknown"
        assert {path.name: path.read_bytes() for path in archived.iterdir()} == original_archive
        # A missing collection is unknown, not retirement or a clean empty inventory.
        for path in incoming.iterdir():
            path.unlink()
        incoming.rmdir()
        missing = subprocess.run(command, capture_output=True, text=True)
        assert missing.returncode == 1
        after = sync.load(state / "state.json")
        assert after["lastInput"]["status"] == "missing-unknown"
        assert after["targets"][target]["current"] == current
        assert after["targets"][target]["history"] == history
        result = subprocess.run([sys.executable, "-B", str(Path(sync.__file__)), "status", "--state-dir", str(state)],
                                capture_output=True, text=True, check=True)
        status = json.loads(result.stdout)
        assert status["targets"][target]["coverage"] == "failed-unknown"
        assert status["targets"][target]["deployment"] == "unobserved"
        assert key.read_text() not in rejected.stdout + rejected.stderr + missing.stdout + missing.stderr + result.stdout
        # Failure status must not bypass collection ownership, even for missing input.
        for owned in (True, False):
            snapshot = copy.deepcopy(database)
            snapshot["targets"][target].update(source=provenance, collection="owned-parent")
            sync.save(state / "state.json", snapshot)
            collection = {"uuid": "owned-parent", "name": sync.project_name(provenance),
                          "version": "collection", "collectionLogic": "AGGREGATE_LATEST_VERSION_CHILDREN",
                          "description": sync.OWNER + ":" + sync.project_identity(provenance) if owned else "another owner"}
            writes = []
            def failure_transport(self, method, path, data=None, *, version=1):
                if method == "GET" and path == "project/owned-parent":
                    return collection
                if method == "GET" and path == "project/owned-parent/property":
                    return []
                assert method == "PUT" and path == "project/owned-parent/property"
                writes.append(data)
            with patch.object(sys, "argv", command[2:]), patch.object(sync.Client, "request", failure_transport):
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    assert sync.main() == 1
            if owned:
                assert {item["propertyName"]: item["propertyValue"] for item in writes}["collection_status"] == "missing-unknown"
            else:
                assert not writes, "failure reporting mutated a collection owned by someone else"
            failed = sync.load(state / "state.json")["targets"][target]
            assert failed["current"] == current and failed["history"] == history
        # No API/callback can be reached when one complete stream is absent.
        record = {"current": copy.deepcopy(current), "pending": {
            "projects": {"native": "new-native", "language": "new-language"},
            "hashes": {"native": "n", "language": "l"}, "complete": ["native"]}}
        before = copy.deepcopy(record)
        try:
            sync.promote(None, record, None)
        except ValueError:
            pass
        else:
            raise AssertionError("partial snapshot promoted")
        assert record == before
        # A cached UUID that an administrator reparented must not be promoted.
        client = sync.Client("https://example.invalid", key)
        def transport(method, path, data=None):
            assert method == "GET", "mutated a cached project before ownership validation"
            return {"uuid": "new-image", "name": sync.project_name(provenance, description["revisionId"], "image"),
                    "version": "inventory", "parent": {"uuid": "another-parent"},
                    "description": sync.OWNER + ":" + sync.project_identity(provenance, description["revisionId"], "image")}
        client.request = transport
        record = {"source": provenance, "collection": "owned-parent", "current": current,
                  "history": history, "pending": dict(description, projects={"image": "new-image"}, complete=["image"])}
        before = copy.deepcopy(record)
        try:
            sync.promote(client, record, lambda: None)
        except ValueError:
            pass
        else:
            raise AssertionError("reparented cached project promoted")
        assert record == before
        # Stock name lookup omits parents; full hierarchy decides safe adoption.
        client = sync.Client("https://example.invalid", key)
        full = {"uuid": "existing", "name": "owned-project", "version": "inventory",
                "parent": {"uuid": "owned-parent"}, "description": sync.OWNER + ":" + "d" * 64}
        def projected(method, path, data=None):
            assert method == "GET"
            if path.startswith("project/lookup?"):
                return dict(full, parent=None)
            assert path == "project/existing"
            return copy.deepcopy(full)
        client.request = projected
        assert client.project("owned-project", "inventory", "owned-parent", identity="d" * 64) == "existing"
        # A colliding short display name must not adopt another full identity.
        try:
            client.project("owned-project", "inventory", "owned-parent", identity="e" * 64)
        except ValueError:
            pass
        else:
            raise AssertionError("adopted a colliding display name with another full identity")
        full.update(version="collection", parent={"uuid": "another-root"},
                    collectionLogic="AGGREGATE_LATEST_VERSION_CHILDREN")
        try:
            client.project("owned-project", "collection", collection=True, identity="d" * 64)
        except ValueError:
            pass
        else:
            raise AssertionError("adopted an existing collection under another root")
        # A stock no-op project PATCH succeeds; a bodyless GET/BOM response does not.
        client = sync.Client("https://example.invalid", key)
        class Unchanged:
            def open(self, request, timeout):
                raise sync.HTTPError(request.full_url, 304, "Not Modified", {}, None)
        client.opener = Unchanged()
        project_path = "project/11111111-1111-4111-8111-111111111111"
        assert client.request("PATCH", project_path, {"active": True, "isLatest": True}) is None
        for method, path in (("GET", project_path), ("PUT", "bom")):
            try:
                client.request(method, path)
            except sync.ApiError as error:
                assert error.status == 304
            else:
                raise AssertionError("unexpected bodyless response accepted")
        # A successful PUT is not proof that an unsafe source was disabled.
        policy = sync.load(Path(sync.__file__).with_name("advisory-policy.json"))
        for persists, expected in ((True, 0), (False, 1)):
            observed = copy.deepcopy(policy)
            observed["nvd"]["enabled"] = not policy["nvd"]["enabled"]
            def configuration(method, path, data=None, *, version=1):
                name = path.split("/")[-2]
                if method == "GET":
                    return {"config": copy.deepcopy(observed[name])}
                if persists:
                    observed[name] = copy.deepcopy(data["config"])
            argv = ["dependency-track-sync", "configure", "--api-url", "http://127.0.0.1:1",
                    "--admin-session-file", str(key)]
            with patch.object(sys, "argv", argv), patch.object(
                    sync, "Client", lambda *args, **kwargs: SimpleNamespace(request=configuration)):
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    assert sync.main() == expected
    print("consumer failure/history/archive boundaries passed")


def origin_regression():
    def path(letter, name, drv=False):
        return "/nix/store/" + letter * 32 + "-" + name + (".drv" if drv else "")
    root, a, alternate, c, x, dev = [path(letter, name) for letter, name in
                                    zip("012345", ("root", "a", "a-dev", "c", "x", "x-dev"))]
    root_drv, a_drv, c_drv, x_drv = [path(letter, name, True) for letter, name in
                                    zip("6789", ("root", "a", "c", "x"))]
    def component(drv, name, outputs):
        return {"bom-ref": drv, "type": "library", "name": name, "version": "1",
                "purl": "pkg:nix/" + name + "@1", "cpe": "cpe:2.3:a:vendor:" + name + ":1:*:*:*:*:*:*:*",
                "properties": [{"name": "nix:drv_path", "value": drv},
                               *({"name": "nix:output_path", "value": output} for output in outputs),
                               {"name": "homelab:operator-note", "value": "preserve"}],
                "externalReferences": [{"type": "vcs", "url": "https://example.invalid/upstream"}]}
    document = {"bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
                "metadata": {"component": component(root_drv, "root", [root])},
                "components": [component(a_drv, "a", [a, alternate]), component(c_drv, "c", [c]),
                               component(x_drv, "x", [x, dev])],
                "dependencies": [{"ref": root_drv, "dependsOn": [a_drv, c_drv]},
                                 {"ref": a_drv, "dependsOn": [x_drv]}, {"ref": c_drv, "dependsOn": [a_drv]}]}
    # A's selected output reaches x-dev only. Its sibling output reaches x via C.
    closure = {root: {"deriver": root_drv, "references": [root, a, c]},
               a: {"deriver": a_drv, "references": [dev]},
               alternate: {"deriver": a_drv, "references": [x]},
               c: {"deriver": c_drv, "references": [alternate]},
               x: {"deriver": x_drv, "references": []},
               dev: {"deriver": x_drv, "references": [dev]}}
    revision = "a" * 40
    source = {"flake": "github:dvicory/homelab/" + revision, "revision": revision,
              "storePath": path("b", "source"), "narHash": "sha256-" + "A" * 43 + "="}
    def origin(identifier, option, drv, output):
        return {"id": identifier, "option": option, "definition": "nixos@host", "kind": "unresolved",
                "aspect": None, "sourceFile": None, "sourceUrl": None,
                "package": {"name": identifier, "drvPath": drv, "outputPath": output}}
    origins = {"schema": 1, "target": "nixosConfigurations.host.config.system.build.toplevel",
               "root": {"drvPath": root_drv, "outPath": root}, "source": source,
               "coverage": {"options": ["environment.systemPackages", "systemd.package"], "complete": False},
               "origins": [origin("a", "environment.systemPackages", a_drv, a),
                           origin("c", "systemd.package", c_drv, c)]}
    original = copy.deepcopy((document, closure, origins))
    enriched, report = homelab_origin_bom.enrich(document, closure, origins)
    assert (document, closure, origins) == original
    affected = next(item for item in report["components"] if item["bomRef"] == x_drv)
    assert set(affected["originIds"]) == {"a", "c"}
    routes = {route["entrypointOutputPath"]: route for route in affected["paths"]}
    assert routes[a]["entrypointPath"] == [a, dev] and routes[a]["outputPaths"] == [dev]
    assert routes[c]["entrypointPath"] == [c, alternate, x] and routes[c]["outputPaths"] == [x]
    assert homelab_origin_bom.enrich(enriched, closure, origins) == (enriched, report)
    for before, after in zip([document["metadata"]["component"], *document["components"]],
                             [enriched["metadata"]["component"], *enriched["components"]]):
        assert {key: value for key, value in before.items() if key not in ("properties", "externalReferences")} == {
            key: value for key, value in after.items() if key not in ("properties", "externalReferences")}
        assert all(prop in after["properties"] for prop in before["properties"])
        assert all(ref in after["externalReferences"] for ref in before["externalReferences"])
    assert enriched["dependencies"] == document["dependencies"]
    # A verified output association outranks the store's absent/alternative deriver hint.
    for hint in (None, a_drv):
        alternate_closure = copy.deepcopy(closure)
        alternate_closure[root]["deriver"] = hint
        alternate_bom, alternate_report = homelab_origin_bom.enrich(document, alternate_closure, origins)
        assert alternate_bom == enriched
        assert alternate_report["root"] == origins["root"]
        root_row = next(item for item in alternate_report["components"] if item["bomRef"] == root_drv)
        assert root_row["closureDerivers"][root] == hint
    bad = copy.deepcopy(origins)
    bad["root"]["outPath"] = a
    try:
        homelab_origin_bom.enrich(document, closure, bad)
    except ValueError:
        pass
    else:
        raise AssertionError("attributed a different runtime root")
    # Reject an attribution source whose evaluated build differs, before source resolution.
    metadata = {"locked": {"type": "github", "owner": "dvicory", "repo": "homelab",
                           "rev": revision, "narHash": source["narHash"]}, "path": source["storePath"]}
    evaluated = {"source": {key: source[key] for key in ("storePath", "revision", "narHash")},
                 "root": {"drvPath": root_drv, "outputPath": a}}
    with patch.object(homelab_origins, "_nix_json", side_effect=[metadata, evaluated]):
        try:
            homelab_origins.collect(source["flake"], {"kind": "nix", "target": origins["target"],
                                    "drvPath": root_drv, "outPath": root, "system": "x86_64-linux"})
        except ValueError:
            pass
        else:
            raise AssertionError("accepted an attribution source for a different build")
    # A source-file symlink cannot manufacture a pinned repository reference.
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        repository = directory / "source"
        repository.mkdir()
        outside = directory / "outside.nix"
        outside.write_text("not part of source")
        (repository / "escaped.nix").symlink_to(outside)
        try:
            homelab_origins._file_in(str(repository), str(repository / "escaped.nix"))
        except ValueError:
            pass
        else:
            raise AssertionError("linked a source file outside the evaluated source")
    print("origin root, multi-route, output, cycle and metadata boundaries passed")


def refresh_regression():
    """Offline protocol spies exercise real archive/lifecycle orchestration, not a stock-server claim."""
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        token = root / "github-token"
        token.write_text("fixture-only-never-transmitted")
        token.chmod(0o600)
        state = root / "state"
        state.mkdir()
        def entry(letter):
            return {"id": letter * 24, "inventoryKey": "b" * 24, "kind": "oci", "system": "x86_64-linux",
                    "state": "referenced", "source": "generated/manifests/" + letter + "/workload.yaml",
                    "location": "declaration", "update": "owning declaration", "pointer": "/spec/image",
                    "resolvedImage": "example.invalid/" + letter + "@sha256:" + "c" * 64,
                    "ociPlatform": "linux/amd64"}
        missing, available = entry("a"), entry("d")
        previous_current = {"revision": ["last-good"], "projects": {"image": "last-good-project"}}
        database = {"schema": 1, "targets": {sync.target_key(missing): {
            "source": missing, "current": copy.deepcopy(previous_current), "history": [], "receipts": [],
            "lastSuccess": sync.now()}}}
        args = SimpleNamespace(repository="dvicory/homelab", branch="main", target=[], state_dir=state,
                               github_token_file=token, max_age_seconds=604800, timeout=1)
        checkpoint = lambda: sync.save(state / "state.json", database)
        plan = {"entries": [missing, available], "unsupported": []}
        receipt = {"run": {"id": 1, "head_sha": "e" * 40, "updated_at": sync.now()}}
        attempts, uploads, transitions = [], [], []
        def acquire(source, admitted, artifacts, repository, directory, archive_directory=None):
            attempts.append(source["id"])
            if source == missing:
                raise ValueError("missing complete artifact")
            directory.mkdir()
            sync.save(directory / "provenance.json", source)
            sync.save(directory / "language.cdx.json", {
                "bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
                "components": [], "dependencies": []})
            security_artifacts.seal(directory, source["inventoryKey"])
            return {"id": 2, "digest": "sha256:" + "f" * 64}
        client = SimpleNamespace(
            project=lambda *values, **options: options["identity"],
            properties=lambda *values: None,
            upload=lambda project, file, timeout: uploads.append((project, file.read_bytes())),
            request=lambda method, path, data: transitions.append((method, path, data)))
        with patch.object(security_artifacts, "discover_plan", return_value=(plan, receipt, [])), \
                patch.object(security_artifacts, "acquire_planned", side_effect=acquire), \
                redirect_stdout(io.StringIO()):
            try:
                sync.refresh(args, database, checkpoint, client)
            except ValueError:
                pass
            else:
                raise AssertionError("one missing artifact became a successful fleet refresh")
            assert attempts == [missing["id"], available["id"]] and len(uploads) == 1
            assert database["targets"][sync.target_key(missing)]["current"] == previous_current
            good = copy.deepcopy(database["targets"][sync.target_key(available)]["current"])
            assert database["expected"][sync.target_key(missing)]["coverage"] == "failed-unknown"
            assert database["expected"][sync.target_key(available)]["coverage"] == "complete-inventory"
            # Removing a declaration cannot retire the retained target or make the next run clean.
            plan["entries"] = [available]
            try:
                sync.refresh(args, database, checkpoint, client)
            except ValueError:
                pass
            else:
                raise AssertionError("plan removal silently retired inventory")
            assert database["expected"][sync.target_key(missing)]["coverage"] == "missing-from-plan-unknown"
            assert database["targets"][sync.target_key(missing)]["current"] == previous_current
            assert database["targets"][sync.target_key(available)]["current"] == good
            assert all(data["active"] for _, _, data in transitions)
            clean = {"schema": 1, "targets": {}}
            sync.refresh(args, clean, lambda: None, client)
            assert clean["refresh"]["status"] == "complete"
            assert clean["targets"][sync.target_key(available)]["current"]["complete"] == ["image"]
            # An interrupted admitted original resumes before a changed/reverted latest run.
            interrupted = root / "interrupted"
            acquire(dict(available, resolvedImage="example.invalid/d@sha256:" + "e" * 64),
                    receipt, [], args.repository, interrupted)
            original, _, _, pending = sync.archive_inventory(interrupted, state)
            record = clean["targets"][sync.target_key(available)]
            record["pending"] = {key: pending[key] for key in ("revision", "revisionId", "hashes", "contentHashes")}
            record["pending"].update(archive=str(original), projects={}, complete=[])
            sync.refresh(args, clean, lambda: None, client)
            assert "pending" not in record and record["current"]["revision"] == good["revision"]
            assert any(item["revision"] == pending["revision"] for item in record["history"])
            before_binding = copy.deepcopy(clean)
            try:
                sync.synchronize(SimpleNamespace(inventory=original, state_dir=state, timeout=1),
                                 clean, lambda: None, client, expected_target="0" * 64)
            except ValueError:
                pass
            else:
                raise AssertionError("pending archive switched lifecycle target")
            assert clean == before_binding
            plan["entries"] = []
            try:
                sync.refresh(args, clean, lambda: None, client)
            except ValueError:
                pass
            else:
                raise AssertionError("zero-target plan became a successful clean fleet")
            assert clean["targets"][sync.target_key(available)]["current"]["complete"] == ["image"]
            plan["entries"] = [available]
            before = len(attempts)
            receipt["run"]["updated_at"] = "2000-01-01T00:00:00+00:00"
            try:
                sync.refresh(args, database, checkpoint, client)
            except ValueError:
                pass
            else:
                raise AssertionError("stale producer run refreshed freshness")
            assert len(attempts) == before
            assert database["targets"][sync.target_key(available)]["current"] == good
            assert database["expected"][sync.target_key(available)]["coverage"] == "failed-unknown"
        # Harmless explicit selection changes preserve active data, with visible history.
        args.target = [available["id"]]
        receipt["run"]["updated_at"] = sync.now()
        with patch.object(security_artifacts, "discover_plan", return_value=(plan, receipt, [])), \
                patch.object(security_artifacts, "acquire_planned", side_effect=acquire), \
                redirect_stdout(io.StringIO()):
            sync.refresh(args, database, checkpoint, client)
        assert database["refresh"]["status"] == "complete"
        assert database["selectionHistory"][-1]["current"]["targetIds"] == [available["id"]]
        assert not database["expected"][sync.target_key(missing)]["selected"]
        assert database["expected"][sync.target_key(missing)]["coverage"] == "missing-from-plan-unknown"
        assert database["targets"][sync.target_key(missing)]["current"] == previous_current
        assert not any(path.endswith("/last-good-project") and not data["active"]
                       for _, path, data in transitions)
        args.branch = "another-source"
        try:
            sync.refresh(args, database, checkpoint, client)
        except ValueError:
            pass
        else:
            raise AssertionError("source trust changed within an existing journal")
        args.branch = "main"
        args.target = []
        unsupported = {"id": "f" * 24, "kind": "nix", "state": "exported", "system": "aarch64-darwin",
                       "target": "darwinConfigurations.fixture.system", "reason": "Linux-only collector"}
        plan["unsupported"] = [unsupported]
        catalogue = {"schema": 1, "targets": {}}
        with patch.object(security_artifacts, "discover_plan", return_value=(plan, receipt, [])), \
                patch.object(security_artifacts, "acquire_planned", side_effect=acquire), \
                redirect_stdout(io.StringIO()):
            sync.refresh(args, catalogue, lambda: None, client)
            assert catalogue["refresh"]["status"] == "complete"
            assert len(catalogue["refresh"]["excluded"]) == 1
            assert len(catalogue["refresh"]["unsupported"]) == 1
            assert not catalogue["expected"][sync.target_key(unsupported)]["selected"]
            args.scope = ["desired", "referenced", "exported"]
            sync.refresh(args, catalogue, lambda: None, client)
            assert catalogue["refresh"]["status"] == "complete-with-unsupported"
            assert catalogue["expected"][sync.target_key(unsupported)]["coverage"] == "unsupported-unknown"
            catalogue_current = copy.deepcopy(catalogue["targets"][sync.target_key(available)]["current"])
            unsupported["inventoryFailure"] = True
            try:
                sync.refresh(args, catalogue, lambda: None, client)
            except ValueError:
                pass
            else:
                raise AssertionError("actual discovery failure was treated as intentional unsupported coverage")
            assert catalogue["refresh"]["status"] == "failed-unknown"
            assert catalogue["expected"][sync.target_key(unsupported)]["coverage"] == "failed-unknown"
            assert catalogue["targets"][sync.target_key(available)]["current"] == catalogue_current
            # A previously scanned image becoming local must not hide a failed
            # ownership/status check behind otherwise healthy selected targets.
            retained = copy.deepcopy(catalogue["targets"][sync.target_key(available)])
            local = dict(available, image="localhost/unpublished:latest", reason="local-only image")
            healthy = entry("e")
            plan.update(entries=[healthy], unsupported=[dict(unsupported, inventoryFailure=False), local])
            blocked = SimpleNamespace(**vars(client))
            def reject_retained(*values, **options):
                if options.get("cached") == retained["collection"]:
                    raise ValueError("retained collection ownership changed")
                return client.project(*values, **options)
            blocked.project = reject_retained
            try:
                sync.refresh(args, catalogue, lambda: None, blocked)
            except ValueError:
                pass
            else:
                raise AssertionError("failed unsupported-status publication became a successful refresh")
            record = catalogue["targets"][sync.target_key(available)]
            assert catalogue["refresh"]["status"] == "failed-unknown"
            assert catalogue["expected"][sync.target_key(available)]["coverage"] == "unsupported-unknown"
            assert record["statusPublishFailed"] is True
            assert record["current"] == retained["current"] and record["history"] == retained["history"]
            assert catalogue["expected"][sync.target_key(healthy)]["coverage"] == "complete-inventory"
        args.scope = None
        host = {"id": "a" * 24, "kind": "nix", "system": "x86_64-linux", "state": "desired",
                "target": "nixosConfigurations.fixture.config.system.build.toplevel",
                "flake": "github:attacker/untrusted/" + "f" * 40}
        origin_calls = []
        args.target = []
        receipt["run"]["updated_at"] = sync.now()
        with patch.object(security_artifacts, "discover_plan", return_value=(
                {"entries": [host], "unsupported": []}, receipt, [])), \
                patch.object(security_artifacts, "acquire_planned", return_value={"id": 3}), \
                patch.object(sync, "synchronize"), \
                patch.object(sync, "annotate_origins", side_effect=lambda options, *rest: origin_calls.append(options.flake)), \
                redirect_stdout(io.StringIO()):
            sync.refresh(args, {"schema": 1, "targets": {}}, lambda: None, client)
        assert origin_calls == ["github:dvicory/homelab/" + receipt["run"]["head_sha"]]
        with patch.dict(os.environ, {"GH_TOKEN": "inherited-not-allowed", "GH_HOST": "untrusted.invalid",
                                     "GH_DEBUG": "api"}):
            with sync.github_credentials(token):
                assert os.environ["GH_TOKEN"] == token.read_text()
                assert os.environ["GH_HOST"] == "github.com" and "GH_DEBUG" not in os.environ
            assert os.environ["GH_TOKEN"] == "inherited-not-allowed"
        token.chmod(0o644)
        try:
            with sync.github_credentials(token):
                raise AssertionError("public credential file admitted")
        except ValueError:
            pass
    print("automatic refresh partial/removal/staleness/source-pin/credential boundaries passed")


if __name__ == "__main__":
    regression()
    origin_regression()
    refresh_regression()
