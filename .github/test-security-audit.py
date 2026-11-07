#!/usr/bin/env python3
"""Small offline inventory contract check; upstream scanner proof is separate."""
import argparse
import copy
import csv
import io
import importlib.util
import json
import os
import sys
from pathlib import Path
import tempfile
import zipfile
from unittest.mock import patch
from types import SimpleNamespace

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("audit", Path(__file__).with_name("security-audit.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

assert list(audit.images({"spec": {"containers": [{"name": "main", "image": "registry/app@sha256:abc"}]},
                          "metadata": {"name": "not-an-image"}})) == [("registry/app@sha256:abc", "/spec/containers/main/image")]
assert audit.identity("same artifact") != audit.identity("another artifact")

inventory = {
    "x86_64-linux": {"nativeSupported": True, "limits": ["not deployed"],
        "roots": [{"target": "nixosConfigurations.any-new-guest.config.system.build.toplevel",
                   "kind": "nix", "system": "x86_64-linux"},
                  {"target": "packages.x86_64-linux.another-package",
                   "kind": "nix", "system": "x86_64-linux"}],
        "images": [{"image": "registry/app:tag", "source": "owner", "system": "x86_64-linux", "kind": "oci"},
                   {"image": "localhost/unpublished:tag", "source": "local-owner", "system": "x86_64-linux", "kind": "oci"}]},
    "aarch64-darwin": {"nativeSupported": False, "limits": ["not deployed"],
        "roots": [{"target": "darwinConfigurations.any-laptop.system", "kind": "nix", "system": "aarch64-darwin"}], "images": []},
}

source = {"path": "/nix/store/selected-source-source", "locked": {"narHash": "sha256-" + "a" * 43 + "="}}
resolved_paths = {
    "drvPath": "/nix/store/n2ys7d0rng1c58qqrfnj7pb66qx8r8vq-zlib-1.3.2.drv",
    "outPath": "/nix/store/4my1cjkysivszznv4342x12r3z2pwdpl-zlib-1.3.2",
}


def rejects(function, *args):
    try:
        function(*args)
    except ValueError:
        pass
    else:
        raise AssertionError(f"{function.__name__} accepted invalid input")


digest = "sha256:" + "a" * 64
assert audit.image_reference("registry.example:5000/app:tag@" + digest) == (
    "registry.example:5000/app", "registry.example:5000/app@" + digest)
assert audit.image_reference("registry/app@" + digest) == ("registry/app", "registry/app@" + digest)
assert audit.image_reference("registry/app:tag") == ("registry/app", "registry/app:tag")
rejects(audit.image_reference, "registry/app:tag@not-a-digest")


def capture(*args):
    if args[0] == "nix":
        # The controller may inspect descriptor names, never selected values.
        assert args[-1] == "path:" + source["path"] + "#securityInventory"
        return json.dumps(inventory)
    assert args[0] == "skopeo" and args[-1] == "docker://registry/app:tag"
    return "sha256:" + "a" * 64 + "\n"




def native_fixture(row):
    """Minimal pinned-upstream-shaped inventory, including collapsed outputs."""
    root = row["outPath"]
    dependency = "/nix/store/6wjykzqf6w3kzfhjc4z7dcd84j0dzsgm-glibc-2.42-84"
    sibling = "/nix/store/24zdslzcp8icc73ck3kawiacaxvsczch-zlib-1.3.2-dev"
    components = [
        {"type": "library", "bom-ref": row["drvPath"], "name": "zlib", "version": "1.3.2",
         "purl": "pkg:nix/zlib@1.3.2", "cpe": "cpe:2.3:a:zlib:zlib:1.3.2:*:*:*:*:*:*:*",
         "properties": [{"name": "nix:output_path", "value": path} for path in (root, sibling)]
                       + [{"name": "nix:drv_path", "value": row["drvPath"]}]},
        {"type": "library", "bom-ref": dependency, "name": "glibc", "version": "2.42-84",
         "purl": "pkg:nix/glibc@2.42-84", "properties": [{"name": "nix:output_path", "value": dependency}]},
    ]
    native = {"bomFormat": "CycloneDX", "specVersion": "1.4", "version": 1,
              "metadata": {"properties": [{"name": "sbom_type", "value": "runtime_only"}],
                           "component": components[0]},
              "components": components[1:],
              "dependencies": [{"ref": row["drvPath"], "dependsOn": [dependency]}, {"ref": dependency}]}
    closure = {root: {"narSize": 1, "narHash": "sha256-test", "deriver": row["drvPath"], "references": [dependency]},
               dependency: {"narSize": 1, "narHash": "sha256-test", "deriver": None, "references": []}}
    stream = io.StringIO()
    fields = ["name", "pname", "version", "patches", "system", "out", "outputs", "store_path",
              "cpe", "purl", "urls", "output_paths_json", "patch_paths_json"]
    writer = csv.DictWriter(stream, fields, quoting=csv.QUOTE_ALL)
    writer.writeheader()
    for component in components:
        outputs = [prop["value"] for prop in component["properties"] if prop["name"] == "nix:output_path"]
        writer.writerow(dict.fromkeys(fields, "") | {
            "name": component["name"] + "-" + component["version"], "pname": component["name"],
            "version": component["version"], "out": outputs[0], "outputs": str(outputs),
            "store_path": component["bom-ref"], "cpe": component.get("cpe", ""), "purl": component["purl"],
            "output_paths_json": json.dumps(outputs), "patch_paths_json": "[]"})
    return native, closure, stream.getvalue()


def forged_manifest(directory, manifest):
    """Model hashed malformed producer output, not just hash tampering."""
    manifest = copy.deepcopy(manifest)
    for name in manifest["files"]:
        path = directory / name
        manifest["files"][name] = {"sha256": audit.security_artifacts.digest(path), "size": path.stat().st_size}
    audit.save(directory / "complete.json", manifest)


def check_native_rejection(directory, row, manifest):
    rejects(audit.security_artifacts.seal, directory, row["inventoryKey"])
    assert not (directory / "complete.json").exists()
    forged_manifest(directory, manifest)
    rejects(audit.security_artifacts.verify, directory, row["inventoryKey"])
    with patch.object(audit, "current_entry", return_value=row), \
            patch.object(audit, "capture", return_value="Trivy test version"), patch.object(audit, "run") as calls:
        rejects(audit.collect, argparse.Namespace(entry="entry.json", directory=str(directory)))
        rejects(audit.scan, argparse.Namespace(directory=str(directory), output="rejected-report"))
        calls.assert_not_called()


def check_real_native_proof(path):
    """Admit persisted actual upstream outputs; no store/registry is consulted."""
    proof = json.loads(Path(path).read_text())["observed_real_closure_proof"]
    for sample in proof.values():
        if "raw_csv" not in sample:
            continue
        native = sample["raw_evidence"][".cdx.json"]
        ref = native["metadata"]["component"]["bom-ref"]
        row = {"kind": "nix", "inventoryKey": "real-proof", "outPath": sample["root"],
               "drvPath": ref if ref.endswith(".drv") else None, "references": list(sample["raw_path_info"])}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            audit.save(directory / "native.cdx.json", native)
            audit.save(directory / "closure.json", sample["raw_path_info"])
            (directory / "native.csv").write_text(sample["raw_csv"])
            audit.save(directory / "language.cdx.json", {"bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1, "components": []})
            audit.save(directory / "provenance.json", row)
            audit.security_artifacts.record_native_evidence(directory, row,
                lambda ref: (_ for _ in ()).throw(AssertionError("tiny proof queried the original store")))
            audit.security_artifacts.seal(directory, row["inventoryKey"])
            audit.security_artifacts.verify(directory, row["inventoryKey"])
            print("Actual sbomnix runtime inventory admitted:", sample["root"])


def check_composite_native(row):
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        native, closure, native_csv = native_fixture(row)
        opaque = "/nix/store/" + "d" * 32 + "-source"
        root = row["outPath"]
        closure[root]["deriver"] = "/nix/store/" + "e" * 32 + "-alternative.drv"
        closure[root]["references"].append(opaque)
        closure[opaque] = {"narSize": 1, "narHash": "sha256-test", "deriver": None, "references": []}
        provenance = dict(row, references=list(closure))
        audit.save(directory / "native.cdx.json", native)
        audit.save(directory / "closure.json", closure)
        audit.save(directory / "provenance.json", provenance)
        audit.save(directory / "language.cdx.json", {"bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1, "components": []})
        (directory / "native.csv").write_text(native_csv)
        with patch.object(audit, "capture", return_value=root + "\n") as query:
            audit.security_artifacts.record_native_evidence(directory, provenance,
                lambda ref: audit.capture("nix-store", "--query", "--outputs", ref).splitlines())
            query.assert_called_once_with("nix-store", "--query", "--outputs", row["drvPath"])
        audit.security_artifacts.seal(directory, row["inventoryKey"])
        evidence = json.loads((directory / "native-evidence.json").read_text())
        assert evidence["coverage"]["opaquePaths"] == [opaque]
        assert evidence["coverage"]["opaquePathCount"] == 1
        assert evidence["coverage"]["noCpePathCount"] == 1
        assert evidence["coverage"]["warning"] == audit.security_artifacts.NATIVE_WARNING
        manifest = json.loads((directory / "complete.json").read_text())
        for change in ("missing-alternative-output", "omitted-opaque", "false-safe-warning"):
            bad = copy.deepcopy(evidence)
            if change == "missing-alternative-output":
                bad["derivationOutputs"][row["drvPath"]] = []
            elif change == "omitted-opaque":
                bad["coverage"]["opaquePaths"] = []
                bad["coverage"]["opaquePathCount"] = 0
            else:
                bad["coverage"]["warning"] = "safe"
            audit.save(directory / "native-evidence.json", bad)
            check_native_rejection(directory, row, manifest)
        audit.save(directory / "native-evidence.json", evidence)
        # Regenerating all auxiliary accounting cannot conceal omitted software,
        # even when its path-info deriver is unavailable.
        native["components"] = []
        native["dependencies"] = [{"ref": row["drvPath"]}]
        audit.save(directory / "native.cdx.json", native)
        (directory / "native.csv").write_text("".join(native_csv.splitlines(keepends=True)[:2]))
        audit.security_artifacts.record_native_evidence(directory, provenance, lambda ref: [root])
        check_native_rejection(directory, row, manifest)


def check_full_native_directory(path):
    directory = Path(path)
    native = json.loads((directory / "native.cdx.json").read_text())
    closure = json.loads((directory / "closure.json").read_text())
    request = json.loads((directory / "request.json").read_text())
    provenance = {"outPath": request["root"], "drvPath": native["metadata"]["component"]["bom-ref"],
                  "references": list(closure)}
    coverage = audit.security_artifacts.native_coverage(directory, provenance)
    print("Actual full native composite inventory admitted:", json.dumps(coverage))
    with tempfile.TemporaryDirectory() as temporary:
        copy_directory = Path(temporary)
        for name in ("native.cdx.json", "native.csv", "closure.json", "native-evidence.json"):
            (copy_directory / name).write_bytes((directory / name).read_bytes())
        # Remove a genuine versioned upstream component from this actual root.
        component = next(component for component in native["components"] if component.get("version") and component.get("cpe"))
        native["components"].remove(component)
        native["dependencies"] = [record for record in native["dependencies"] if record["ref"] != component["bom-ref"]]
        for record in native["dependencies"]:
            if "dependsOn" in record:
                record["dependsOn"] = [ref for ref in record["dependsOn"] if ref != component["bom-ref"]]
        audit.save(copy_directory / "native.cdx.json", native)
        with (copy_directory / "native.csv").open(newline="") as stream:
            reader = csv.DictReader(stream)
            fields = reader.fieldnames
            rows = [row for row in reader if row["store_path"] != component["bom-ref"]]
        with (copy_directory / "native.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fields, quoting=csv.QUOTE_ALL)
            writer.writeheader()
            writer.writerows(rows)
        outputs = json.loads((copy_directory / "native-evidence.json").read_text())["derivationOutputs"]
        audit.security_artifacts.record_native_evidence(copy_directory, provenance, lambda ref: outputs[ref])
        rejects(audit.security_artifacts.native_coverage, copy_directory, provenance)


def check_trusted_restore(directory, row):
    repository, branch, sha = "owner/repository", "main", "a" * 40
    workflow = audit.security_artifacts.WORKFLOW
    producer = {"GITHUB_REPOSITORY": repository, "GITHUB_WORKFLOW_REF": f"{repository}/{workflow}@refs/heads/{branch}",
                "GITHUB_REF": "refs/heads/" + branch, "GITHUB_EVENT_NAME": "schedule", "GITHUB_SHA": sha}
    with patch.dict(os.environ, producer):
        audit.security_artifacts.seal(directory, row["inventoryKey"])
    artifact = {"id": 1, "name": f"security-inventory-v1-{row['id']}-{row['inventoryKey']}",
                "expired": False, "created_at": "2026-11-06", "size_in_bytes": 1024,
                "workflow_run": {"id": 2, "head_branch": branch, "head_sha": sha}}
    run = {"repository": {"full_name": repository}, "head_repository": {"full_name": repository},
           "path": workflow, "head_branch": branch, "event": "schedule", "head_sha": sha}
    # These GitHub metadata failures must reject before downloading any bytes.
    for field, value in (("repository", {"full_name": "other/repository"}),
                         ("head_repository", {"full_name": "fork/repository"}),
                         ("path", ".github/workflows/untrusted.yml"), ("head_branch", "other"),
                         ("event", "pull_request")):
        with patch.object(audit.security_artifacts, "api", side_effect=[{"artifacts": [artifact]}, dict(run, **{field: value})]), \
                patch.object(audit.security_artifacts.subprocess, "Popen") as download:
            audit.security_artifacts.restore(row, Path("must-not-restore"), repository, branch)
            download.assert_not_called()
            assert not Path("must-not-restore").exists()
    with patch.object(audit.security_artifacts, "api", side_effect=[{"artifacts": [artifact]}, dict(run, head_sha="b" * 40)]), \
            patch.object(audit.security_artifacts.subprocess, "Popen") as download:
        rejects(audit.security_artifacts.restore, row, Path("must-not-restore"), repository, branch)
        download.assert_not_called()
    archive_bytes = io.BytesIO()
    with zipfile.ZipFile(archive_bytes, "w") as archive:
        for path in directory.iterdir():
            archive.write(path, path.name)
    process = SimpleNamespace(stdout=io.BytesIO(archive_bytes.getvalue()), wait=lambda: 0, poll=lambda: 0)
    with patch.object(audit.security_artifacts, "api", side_effect=[{"artifacts": [artifact]}, run]), \
            patch.object(audit.security_artifacts.subprocess, "Popen", return_value=process):
        audit.security_artifacts.restore(row, Path("restored"), repository, branch)
    audit.security_artifacts.verify(Path("restored"), row["inventoryKey"], producer, row)
    rejects(audit.security_artifacts.verify, Path("restored"), row["inventoryKey"], dict(producer, GITHUB_SHA="b" * 40))

def check_native_resolution():
    """Exercise the actual Nix serializer, not an assumed JSON response."""
    previous = Path.cwd()
    try:
        os.chdir(Path(__file__).resolve().parents[1])
        executor = audit.capture("nix", "eval", "--raw", "--impure", "--expr", "builtins.currentSystem").strip()
        metadata = audit.source_metadata()
        descriptor = {"kind": "nix", "system": executor,
                      "target": f"packages.{executor}.compute-runtime",
                      "plannedSourceNarHash": metadata["locked"]["narHash"]}
        row = audit.resolve_row(descriptor)
        outputs = audit.capture("nix-store", "--query", "--outputs", row["drvPath"]).splitlines()
        assert row["outPath"] in outputs
        foreign = "aarch64-linux" if executor != "aarch64-linux" else "x86_64-linux"
        rejects(audit.resolve_row, dict(descriptor, system=foreign))
        print("Actual native Nix identity resolved:", row["drvPath"], row["outPath"])
    finally:
        os.chdir(previous)


with tempfile.TemporaryDirectory() as directory:
    previous = Path.cwd()
    try:
        os.chdir(directory)
        args = argparse.Namespace(output="plan.json", github_output="outputs")
        with patch.object(audit, "capture", capture), patch.object(audit, "source_metadata", return_value=source), \
                patch.object(audit, "inventory_key", side_effect=AssertionError("controller constructed an artifact key")):
            audit.plan(args)
        plan = json.loads(Path("plan.json").read_text())
        assert len(plan["entries"]) == 3
        assert len(plan["unsupported"]) == 2
        assert plan["deployed"]["status"] == "unobserved"
        assert plan["entries"][0]["target"].startswith("nixosConfigurations.any-new-guest")
        assert plan["entries"][2]["resolvedImage"] == "registry/app@sha256:" + "a" * 64
        assert plan["entries"][2]["ociPlatform"] == "linux/amd64"
        for entry in plan["entries"]:
            assert entry["plannedSourceNarHash"] == source["locked"]["narHash"]
            assert not {"inventoryKey", "drvPath", "outPath", "sourcePath", "sourceNarHash"} & entry.keys()
        assert any(row["system"] == "aarch64-darwin" and row["target"].startswith("darwinConfigurations.")
                   for row in plan["unsupported"])
        assert "matrix=" in Path("outputs").read_text()
        descriptor = plan["entries"][0]
        row = dict(descriptor, sourcePath=source["path"],
                   sourceNarHash=source["locked"]["narHash"], **resolved_paths)
        row["inventoryKey"] = audit.inventory_key(row)
        assert not {"inventoryKey", "drvPath", "outPath"} & descriptor.keys()
        with patch.object(audit, "source_metadata", return_value=source), \
                patch.object(audit, "capture", side_effect=AssertionError("OCI resolver evaluated a Nix target")):
            oci = audit.resolve_row(plan["entries"][2])
        assert oci["resolvedImage"] == plan["entries"][2]["resolvedImage"]
        assert oci["ociPlatform"] == "linux/amd64"
        assert oci["sourcePath"] == source["path"] and oci["sourceNarHash"] == source["locked"]["narHash"]
        assert not {"drvPath", "outPath"} & oci.keys()
        assert oci["inventoryKey"] == audit.inventory_key(oci)
        assert audit.inventory_key(dict(oci, resolvedImage="registry/app@sha256:" + "b" * 64)) != oci["inventoryKey"]
        for field in ("drvPath", "outPath", "system"):
            assert audit.inventory_key(dict(row, **{field: row[field] + "-changed"})) != row["inventoryKey"]
        with patch.object(audit, "SBOMNIX", "another-tool-revision"):
            assert audit.inventory_key(row) != row["inventoryKey"]
        with patch.object(audit.security_artifacts, "digest", return_value="b" * 64):
            assert audit.inventory_key(row) != row["inventoryKey"]

        with patch.object(audit, "source_metadata", return_value=source), \
                patch.object(audit, "capture", side_effect=AssertionError("evaluated stale planned source")):
            rejects(audit.resolve_row, dict(descriptor, plannedSourceNarHash="sha256-stale"))

        audit.save("entry.json", row)
        with patch.object(audit, "source_metadata", return_value=source), \
                patch.object(audit, "capture", side_effect=AssertionError("re-evaluated resolved target")):
            assert audit.current_entry("entry.json") == row
            for field in ("plannedSourceNarHash", "sourceNarHash", "sourcePath", "inventoryKey", "drvPath", "outPath"):
                audit.save("stale.json", dict(row, **{field: row[field] + "-stale"}))
                rejects(audit.current_entry, "stale.json")
            with patch.object(audit, "SBOMNIX", "another-tool-revision"):
                rejects(audit.current_entry, "entry.json")
            with patch.object(audit.security_artifacts, "digest", return_value="b" * 64):
                rejects(audit.current_entry, "entry.json")
        with patch.object(audit, "source_metadata", return_value=dict(source, locked={"narHash": "sha256-stale"})):
            rejects(audit.current_entry, "entry.json")

        built = [dict(drvPath=row["drvPath"], outputs={"out": row["outPath"]})]
        audit.verify_build_output(row, built)
        for result in ([], built * 2, [dict(built[0], drvPath="/nix/store/another.drv")],
                       [dict(built[0], outputs={"out": "/nix/store/another"})]):
            rejects(audit.verify_build_output, row, result)

        Path("inventory").mkdir()
        audit.save("entry.json", row)
        native, closure, native_csv = native_fixture(row)
        audit.save("inventory/language.cdx.json", {"bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1, "components": []})
        audit.save("inventory/provenance.json", dict(row, state="built", references=list(closure)))
        rejects(audit.security_artifacts.seal, Path("inventory"), row["inventoryKey"])
        for name in ("native.cdx.json", "native.csv", "closure.json"):
            Path("inventory", name).write_text("{}")
        rejects(audit.security_artifacts.seal, Path("inventory"), row["inventoryKey"])
        audit.save("inventory/native.cdx.json", native)
        audit.save("inventory/closure.json", closure)
        Path("inventory/native.csv").write_text(native_csv)
        audit.security_artifacts.record_native_evidence(Path("inventory"), row,
            lambda ref: (_ for _ in ()).throw(AssertionError("fixture queried the original store")))
        audit.security_artifacts.seal(Path("inventory"), row["inventoryKey"])
        check_composite_native(row)
        manifest = json.loads(Path("inventory/complete.json").read_text())
        originals = {path.name: path.read_bytes() for path in Path("inventory").iterdir()}
        # Hash-consistent missing component, root, output, CSV row, and graph
        # counterexamples must fail at seal, admission, reuse and pre-scan.
        malformed = [("native.cdx.json", {}), ("native.csv", "{}"), ("closure.json", {})]
        value = copy.deepcopy(native)
        value["components"] = []
        malformed.append(("native.cdx.json", value))
        value = copy.deepcopy(native)
        del value["metadata"]["component"]
        malformed.append(("native.cdx.json", value))
        value = copy.deepcopy(native)
        value["metadata"]["component"] = value["components"][0]
        value["components"] = [native["metadata"]["component"]]
        malformed.append(("native.cdx.json", value))
        value = copy.deepcopy(native)
        value["metadata"]["component"]["properties"] = [prop for prop in value["metadata"]["component"]["properties"]
                                                       if prop["value"] != row["outPath"]]
        malformed.append(("native.cdx.json", value))
        value = copy.deepcopy(native)
        value["metadata"]["properties"].append({"name": "sbom_dependencies_depth", "value": "1"})
        malformed.append(("native.cdx.json", value))
        value = copy.deepcopy(native)
        value["dependencies"][0]["dependsOn"] = []
        malformed.append(("native.cdx.json", value))
        malformed.append(("native.csv", native_csv.splitlines(keepends=True)[0] + native_csv.splitlines(keepends=True)[1]))
        malformed.append(("native.csv", native_csv.replace('pkg:nix/glibc@2.42-84', 'pkg:nix/other@2.42-84')))
        malformed.append(("native.csv", native_csv.replace(row["outPath"], "/nix/store/" + "b" * 32 + "-other")))
        value = copy.deepcopy(closure)
        del value[next(path for path in closure if path != row["outPath"])]
        malformed.append(("closure.json", value))
        value = copy.deepcopy(closure)
        value[row["outPath"]]["references"].append("/nix/store/" + "c" * 32 + "-omitted")
        malformed.append(("closure.json", value))
        value = dict(row, references=[row["outPath"]])
        malformed.append(("provenance.json", value))
        for name, value in malformed:
            if isinstance(value, str):
                Path("inventory", name).write_text(value)
            else:
                audit.save(Path("inventory", name), value)
            check_native_rejection(Path("inventory"), row, manifest)
            for filename, content in originals.items():
                Path("inventory", filename).write_bytes(content)
        with patch.object(audit, "source_metadata", return_value=source), \
                patch.object(audit, "capture", return_value="Trivy test version"), patch.object(audit, "run") as calls:
            audit.collect(argparse.Namespace(entry="entry.json", directory="inventory", staging_directory=None))
            calls.assert_not_called()  # no rebuild, registry access or inventory regeneration
        reused = json.loads(Path("inventory/provenance.json").read_text())
        assert reused["reused"] and reused["state"] == "built"
        assert reused["references"] == list(closure)
        rejects(audit.security_artifacts.verify, Path("inventory"), row["inventoryKey"], None, dict(row, outPath="/nix/store/other"))
        audit.save("inventory/provenance.json", dict(reused, ociArchive=row["outPath"]))
        rejects(audit.security_artifacts.seal, Path("inventory"), row["inventoryKey"])
        audit.save("inventory/archive.cdx.json", {"bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1, "components": []})
        audit.security_artifacts.seal(Path("inventory"), row["inventoryKey"])
        check_trusted_restore(Path("inventory"), row)
        Path("source").write_text("actual bytes")
        with patch.object(audit.os, "link", side_effect=PermissionError(audit.errno.EPERM, "protected hardlink")):
            audit.stage_file("source", "staged-copy")
        assert Path("staged-copy").read_text() == "actual bytes"
        Path("inventory/language.cdx.json").write_text('{"tampered":true}')
        try:
            audit.security_artifacts.verify(Path("inventory"), row["inventoryKey"])
        except ValueError:
            pass
        else:
            raise AssertionError("tampered inventory accepted")
        with zipfile.ZipFile("bad.zip", "w") as archive:
            archive.writestr("../escape", "untrusted")
        try:
            audit.security_artifacts.unpack("bad.zip", Path("unpacked"))
        except ValueError:
            pass
        else:
            raise AssertionError("unsafe artifact path accepted")
    finally:
        os.chdir(previous)
print("inventory contract passed")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--native-proof", help="persisted generic-native-proof.json with actual upstream CSV/CDX/path-info")
parser.add_argument("--native-directory", action="append", default=[], help="actual full-root raw CSV/CDX/closure/request plus collected native-evidence.json")
parser.add_argument("--native-resolve", action="store_true", help="verify actual native Nix package identity without building")
args = parser.parse_args()
if args.native_resolve:
    check_native_resolution()
if args.native_proof:
    check_real_native_proof(args.native_proof)
for directory in args.native_directory:
    check_full_native_directory(directory)
