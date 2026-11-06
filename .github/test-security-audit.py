#!/usr/bin/env python3
"""Small offline inventory contract check; upstream scanner proof is separate."""
import argparse
import importlib.util
import json
import os
import sys
from pathlib import Path
import tempfile
import zipfile
from unittest.mock import patch

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("audit", Path(__file__).with_name("security-audit.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

assert list(audit.images({"spec": {"containers": [{"name": "main", "image": "registry/app@sha256:abc"}]},
                          "metadata": {"name": "not-an-image"}})) == [("registry/app@sha256:abc", "/spec/containers/main/image")]
assert audit.identity("same artifact") == audit.identity("same artifact")
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
resolved_paths = {"drvPath": "/nix/store/selected.drv", "outPath": "/nix/store/selected"}


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


native_calls = []
executor = "x86_64-linux"


def native_capture(*args):
    native_calls.append(args)
    assert args[:2] == ("nix", "eval")
    if "builtins.currentSystem" in args:
        assert "--expr" in args and "--raw" in args
        return executor
    assert "path:" + source["path"] + "#" + inventory["x86_64-linux"]["roots"][0]["target"] in args
    assert "--json" in args and "--apply" in args
    return json.dumps(resolved_paths)

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
        with patch.object(audit, "source_metadata", return_value=source), patch.object(audit, "capture", native_capture):
            row = audit.resolve_row(descriptor)
        assert len(native_calls) == 2  # executor plus exactly one selected target
        assert {name: row[name] for name in resolved_paths} == resolved_paths
        assert row["sourcePath"] == source["path"]
        assert row["sourceNarHash"] == source["locked"]["narHash"]
        assert row["inventoryKey"] == audit.inventory_key(row)
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
        executor = "aarch64-linux"
        native_calls.clear()
        with patch.object(audit, "source_metadata", return_value=source), patch.object(audit, "capture", native_capture):
            rejects(audit.resolve_row, descriptor)
        assert len(native_calls) == 1 and "builtins.currentSystem" in native_calls[0]
        executor = "x86_64-linux"

        audit.save("descriptor.json", descriptor)
        with patch.object(audit, "source_metadata", return_value=source), patch.object(audit, "capture", native_capture):
            audit.resolve(argparse.Namespace(entry="descriptor.json", output="resolved.json", github_output="resolve-outputs"))
        assert json.loads(Path("resolved.json").read_text()) == row
        assert Path("resolve-outputs").read_text().strip() == "inventoryKey=" + row["inventoryKey"]
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
        Path("inventory/language.cdx.json").write_text("{}")
        audit.save("inventory/provenance.json", dict(row, state="built", references=["/nix/store/actual"]))
        try:
            audit.security_artifacts.seal(Path("inventory"), row["inventoryKey"])
        except ValueError:
            pass
        else:
            raise AssertionError("incomplete native inventory sealed")
        for name in ("native.cdx.json", "native.csv", "closure.json"):
            Path("inventory", name).write_text("{}")
        audit.security_artifacts.seal(Path("inventory"), row["inventoryKey"])
        with patch.object(audit, "source_metadata", return_value=source), \
                patch.object(audit, "capture", return_value="Trivy test version"), patch.object(audit, "run") as calls:
            audit.collect(argparse.Namespace(entry="entry.json", directory="inventory", staging_directory=None))
            calls.assert_not_called()  # no rebuild, registry access or inventory regeneration
        reused = json.loads(Path("inventory/provenance.json").read_text())
        assert reused["reused"] and reused["state"] == "built"
        assert reused["references"] == ["/nix/store/actual"]
        audit.save("inventory/provenance.json", dict(reused, ociArchive="/nix/store/image"))
        try:
            audit.security_artifacts.seal(Path("inventory"), row["inventoryKey"])
        except ValueError:
            pass
        else:
            raise AssertionError("missing identified OCI archive inventory accepted")
        Path("inventory/archive.cdx.json").write_text("{}")
        audit.security_artifacts.seal(Path("inventory"), row["inventoryKey"])
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
