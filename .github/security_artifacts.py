"""Bounded, hash-verified reuse of inventories from this workflow's main runs."""
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

FILES = {"native.cdx.json", "native.csv", "closure.json", "language.cdx.json", "archive.cdx.json", "provenance.json"}
WORKFLOW = ".github/workflows/vulnerability-management.yml"
EVENTS = {"push", "schedule", "workflow_dispatch"}
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_EXPANDED = 256 * 1024 * 1024


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def store_paths(values):
    if (not isinstance(values, list)
            or any(not isinstance(value, str) or not re.fullmatch(r"/nix/store/[0-9a-z]{32}-[^/\s]+", value)
                   for value in values) or len(values) != len(set(values))):
        raise ValueError("invalid or duplicate native store paths")
    return set(values)


def native_coverage(directory, provenance):
    """Check the pinned sbomnix CSV/CDX representation, without a live store.

    sbomnix groups outputs by derivation and may list sibling outputs outside
    the runtime closure. Those are not extra realized/runtime coverage. Every
    recorded closure path must nevertheless be represented; upstream omissions
    (including non-package artifacts) make an inventory partial, never clean.
    """
    closure = json.loads((directory / "closure.json").read_text())
    if not isinstance(closure, dict) or not closure:
        raise ValueError("native closure is empty or malformed")
    paths = store_paths(list(closure))
    if paths != store_paths(provenance.get("references")) or provenance.get("outPath") not in paths:
        raise ValueError("native closure/provenance/selected output mismatch")
    pending, reachable = [provenance["outPath"]], set()
    for path, record in closure.items():
        if (not isinstance(record, dict) or type(record.get("narSize")) is not int
                or record["narSize"] < 0 or not isinstance(record.get("narHash"), str)
                or not record["narHash"]):
            raise ValueError("malformed native closure record: " + path)
        if not store_paths(record.get("references")) <= paths:
            raise ValueError("native closure omits a recorded reference")
    while pending:
        path = pending.pop()
        if path not in reachable:
            reachable.add(path)
            pending.extend(closure[path]["references"])
    if reachable != paths:
        raise ValueError("native closure includes paths unreachable from selected output")

    cdx = json.loads((directory / "native.cdx.json").read_text())
    if (not isinstance(cdx, dict) or cdx.get("bomFormat") != "CycloneDX"
            or cdx.get("specVersion") != "1.4" or cdx.get("version") != 1
            or not isinstance(cdx.get("metadata"), dict)
            or not isinstance(cdx.get("components"), list)
            or not isinstance(cdx.get("dependencies"), list)):
        raise ValueError("malformed sbomnix CycloneDX inventory")
    metadata = cdx["metadata"]
    if (not isinstance(metadata.get("properties"), list)
            or any(not isinstance(prop, dict) for prop in metadata["properties"])
            or {"name": "sbom_type", "value": "runtime_only"} not in metadata["properties"]):
        raise ValueError("native inventory is not an unbounded runtime inventory")
    if any(prop.get("name") == "sbom_dependencies_depth" for prop in metadata.get("properties", [])):
        raise ValueError("depth-limited native inventory cannot be complete")
    root = metadata.get("component")
    components, covered = {}, {}
    for component in [root, *cdx["components"]]:
        if (not isinstance(component, dict) or not isinstance(component.get("bom-ref"), str)
                or not isinstance(component.get("name"), str) or not component["name"]
                or not isinstance(component.get("version"), str)
                or not isinstance(component.get("properties"), list)):
            raise ValueError("native component identity/properties absent")
        if any(not isinstance(prop, dict) or not isinstance(prop.get("name"), str)
               or not isinstance(prop.get("value"), str) for prop in component["properties"]):
            raise ValueError("malformed native component property")
        ref = component["bom-ref"]
        if ref in components:
            raise ValueError("duplicate native component identity")
        outputs = store_paths([prop["value"] for prop in component["properties"] if prop["name"] == "nix:output_path"])
        drvs = [prop["value"] for prop in component["properties"] if prop["name"] == "nix:drv_path"]
        store_paths([ref])
        if not outputs or (drvs != [ref] if ref.endswith(".drv") else drvs or ref not in outputs):
            raise ValueError("native component derivation/output identity mismatch")
        if not outputs & paths:
            raise ValueError("native component represents no runtime closure output")
        for path in outputs & paths:
            if path in covered or (ref.endswith(".drv") and closure[path].get("deriver") not in (None, ref)):
                raise ValueError("native output has inconsistent component/deriver")
            covered[path] = ref
        components[ref] = (component, outputs)
    if set(covered) != paths:
        raise ValueError("partial native inventory; unrepresented closure paths: " + ", ".join(sorted(paths - covered.keys())))
    if provenance["outPath"] not in components[root["bom-ref"]][1]:
        raise ValueError("native metadata root does not represent selected output")
    if root["bom-ref"].endswith(".drv") and root["bom-ref"] != provenance.get("drvPath"):
        raise ValueError("native metadata root derivation differs from selected derivation")
    dependencies = {}
    for record in cdx["dependencies"]:
        if (not isinstance(record, dict) or record.get("ref") not in components
                or record["ref"] in dependencies or not isinstance(record.get("dependsOn", []), list)
                or not set(record.get("dependsOn", [])) <= components.keys()):
            raise ValueError("native dependency identities are inconsistent")
        dependencies[record["ref"]] = set(record.get("dependsOn", []))
    if dependencies.keys() != components.keys():
        raise ValueError("native dependency records omit components")
    for path, record in closure.items():
        expected = {covered[reference] for reference in record["references"]} - {covered[path]}
        if not expected <= dependencies[covered[path]]:
            raise ValueError("native dependency graph omits closure references")

    with (directory / "native.csv").open(newline="") as stream:
        rows = csv.DictReader(stream)
        if not {"store_path", "pname", "version", "out", "output_paths_json", "cpe", "purl"} <= set(rows.fieldnames or []):
            raise ValueError("sbomnix CSV transport columns absent")
        seen = set()
        for row in rows:
            ref = row["store_path"]
            if ref not in components or ref in seen or None in row or None in row.values():
                raise ValueError("native CSV component identity/row mismatch")
            seen.add(ref)
            component, outputs = components[ref]
            if (store_paths(json.loads(row["output_paths_json"])) != outputs
                    or (row["out"] and row["out"] not in outputs)
                    or any(row[column] != component.get(field, "") for column, field in
                           (("pname", "name"), ("version", "version"), ("cpe", "cpe"), ("purl", "purl")))):
                raise ValueError("native CSV/CDX component or output paths differ")
        if seen != components.keys():
            raise ValueError("native CSV omits CDX components")


def seal(directory, key):
    manifest = {"inventoryKey": key, "files": {
        path.name: {"sha256": digest(path), "size": path.stat().st_size}
        for path in directory.iterdir() if path.name in FILES
    }, "producer": {name: os.environ.get(name) for name in (
        "GITHUB_REPOSITORY", "GITHUB_WORKFLOW_REF", "GITHUB_REF", "GITHUB_EVENT_NAME", "GITHUB_SHA")}}
    if sum(record["size"] for record in manifest["files"].values()) > MAX_EXPANDED:
        raise ValueError("inventory exceeds reusable artifact size limit")
    (directory / "complete.json").write_text(json.dumps(manifest, indent=2) + "\n")
    try:
        verify(directory, key)
    except Exception:
        (directory / "complete.json").unlink()
        raise


def verify(directory, key, producer=None, entry=None):
    manifest = json.loads((directory / "complete.json").read_text())
    if manifest["inventoryKey"] != key or set(manifest["files"]) - FILES:
        raise ValueError("inventory identity or file allowlist mismatch")
    if not {"language.cdx.json", "provenance.json"} <= set(manifest["files"]):
        raise ValueError("required inventory files absent")
    if sum(record["size"] for record in manifest["files"].values()) > MAX_EXPANDED:
        raise ValueError("inventory manifest size exceeds 256 MiB")
    if {path.name for path in directory.iterdir()} != set(manifest["files"]) | {"complete.json"}:
        raise ValueError("unexpected inventory entries")
    for name, record in manifest["files"].items():
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size != record["size"] or digest(path) != record["sha256"]:
            raise ValueError("inventory hash/size/type mismatch: " + name)
    provenance = json.loads((directory / "provenance.json").read_text())
    if provenance.get("inventoryKey") != key:
        raise ValueError("provenance inventory identity mismatch")
    if entry is not None:
        for field in ("id", "kind", "system", "drvPath", "outPath", "resolvedImage", "ociPlatform"):
            if provenance.get(field) != entry.get(field):
                raise ValueError("cached artifact declaration mismatch: " + field)
    if provenance["kind"] not in ("nix", "oci"):
        raise ValueError("unsupported inventory kind")
    required = {"native.cdx.json", "native.csv", "closure.json"} if provenance["kind"] == "nix" else set()
    if provenance.get("ociArchive"):
        required.add("archive.cdx.json")
    if not required <= set(manifest["files"]):
        raise ValueError("kind-specific inventory files absent: " + ", ".join(sorted(required - set(manifest["files"]))))
    if provenance["kind"] == "nix":
        native_coverage(directory, provenance)
    if producer is not None and manifest["producer"] != producer:
        raise ValueError("inventory producer does not match GitHub's run metadata")
    return manifest


def unpack(archive, directory):
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        names = [entry.filename for entry in entries]
        if len(names) > len(FILES) + 1 or len(set(names)) != len(names):
            raise ValueError("inventory archive entry count/duplicates rejected")
        if set(names) - (FILES | {"complete.json"}):
            raise ValueError("inventory archive path rejected")
        if sum(entry.file_size for entry in entries) > MAX_EXPANDED:
            raise ValueError("inventory archive expanded size exceeds 256 MiB")
        for entry in entries:
            mode = (entry.external_attr >> 16) & 0o170000
            if entry.is_dir() or mode not in (0, 0o100000):
                raise ValueError("inventory archive contains a non-regular file")
        source.extractall(directory)  # exact flat allowlist, sizes/types validated above


def api(*args):
    return json.loads(subprocess.check_output(["gh", "api", *args], text=True))


def restore(entry, directory, repository, branch):
    name = f"security-inventory-v1-{entry['id']}-{entry['inventoryKey']}"
    artifacts = api("--method", "GET", f"repos/{repository}/actions/artifacts",
                    "-f", "name=" + name, "-f", "per_page=100")["artifacts"]
    for artifact in sorted(artifacts, key=lambda item: item["created_at"], reverse=True):
        reference = artifact.get("workflow_run") or {}
        if artifact["name"] != name or artifact["expired"] or reference.get("head_branch") != branch:
            continue
        run = api(f"repos/{repository}/actions/runs/{reference['id']}")
        if (run["repository"]["full_name"] != repository or run["head_repository"]["full_name"] != repository
                or run["path"] != WORKFLOW or run["head_branch"] != branch or run["event"] not in EVENTS):
            continue
        sha = run["head_sha"]
        if not re.fullmatch("[0-9a-f]{40}", sha) or reference.get("head_sha") != sha:
            raise ValueError("artifact/run producer SHA mismatch")
        if artifact["size_in_bytes"] > MAX_ARCHIVE:
            raise ValueError("inventory archive compressed size exceeds 64 MiB")
        producer = {"GITHUB_REPOSITORY": repository, "GITHUB_WORKFLOW_REF": f"{repository}/{WORKFLOW}@refs/heads/{branch}",
                    "GITHUB_REF": "refs/heads/" + branch, "GITHUB_EVENT_NAME": run["event"], "GITHUB_SHA": sha}
        # gh owns authentication/redirect handling; never forward our read token
        # to a signed blob URL ourselves. Bound bytes before any ZIP parsing.
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "inventory.zip"
            process = subprocess.Popen(["gh", "api", f"repos/{repository}/actions/artifacts/{artifact['id']}/zip"], stdout=subprocess.PIPE)
            try:
                with archive.open("wb") as stream:
                    size = 0
                    for chunk in iter(lambda: process.stdout.read(1024 * 1024), b""):
                        size += len(chunk)
                        if size > MAX_ARCHIVE:
                            raise ValueError("inventory download exceeds 64 MiB")
                        stream.write(chunk)
                if process.wait() != 0:
                    raise RuntimeError("inventory download failed")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdout.close()
            directory.mkdir(parents=True, exist_ok=False)
            unpack(archive, directory)
            verify(directory, entry["inventoryKey"], producer, entry)
        print(f"Reused verified inventory artifact {artifact['id']} from {sha}")
        return
    print("No matching trusted inventory; collect will realize the declared artifact")
