"""Bounded, hash-verified reuse of inventories from this workflow's main runs."""
import copy
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile
from urllib.parse import parse_qsl, quote

FILES = {"native.cdx.json", "native.csv", "closure.json", "native-evidence.json", "native-identity.cdx.json", "native-identity.provenance.json", "language.cdx.json", "archive.cdx.json", "provenance.json"}
WORKFLOW = ".github/workflows/vulnerability-management.yml"
EVENTS = {"push", "schedule", "workflow_dispatch"}
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_EXPANDED = 256 * 1024 * 1024
NATIVE_WARNING = "Opaque/unversioned outputs may contain application code with unknown CVE identity; no-CPE outputs lack native CPE matching. Composite inventory completeness is not complete CVE coverage, a clean scan, or a nonaffected verdict."


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


def record_native_evidence(directory, provenance, query_outputs):
    """Retain metadata evidence, not substitute components or CVE verdicts."""
    closure = json.loads((directory / "closure.json").read_text())
    cdx = json.loads((directory / "native.cdx.json").read_text())
    root = cdx["metadata"]["component"]
    components = [root, *cdx["components"]]
    owners, outputs, unversioned, no_cpe = {}, {}, set(), set()
    for component in components:
        ref = component["bom-ref"]
        represented = {prop["value"] for prop in component["properties"] if prop["name"] == "nix:output_path"} & closure.keys()
        if not component["version"]:
            unversioned.update(represented)
        if not component.get("cpe"):
            no_cpe.update(represented)
        for path in represented:
            owners[path] = ref
            # Nix records one deriver hint, not the only derivation capable of
            # producing an output. Retain the claimed derivation's real outputs.
            if ref.endswith(".drv") and closure[path].get("deriver") not in (None, ref) and ref not in outputs:
                outputs[ref] = sorted(store_paths(query_outputs(ref)))
    opaque = sorted(closure.keys() - owners.keys())
    evidence = {"derivationOutputs": outputs, "coverage": {
        "closurePathCount": len(closure), "representedPathCount": len(owners),
        "opaquePathCount": len(opaque), "opaquePaths": opaque,
        "unversionedPathCount": len(unversioned), "unversionedPaths": sorted(unversioned),
        "noCpePathCount": len(no_cpe), "noCpePaths": sorted(no_cpe),
        "warning": NATIVE_WARNING}}
    (directory / "native-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")


def native_coverage(directory, provenance):
    """Check the pinned sbomnix CSV/CDX representation, without a live store.

    sbomnix groups outputs by derivation and may list sibling outputs outside
    the runtime closure. Preserve its raw documents. The closure ledger covers
    opaque unversioned raw paths separately, with unknown CVE identity; a
    missing versioned/derived software output is never classified as opaque.
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
    evidence = json.loads((directory / "native-evidence.json").read_text())
    if (not isinstance(evidence, dict) or set(evidence) != {"derivationOutputs", "coverage"}
            or not isinstance(evidence["coverage"], dict)
            or set(evidence["coverage"]) != {"closurePathCount", "representedPathCount", "opaquePathCount", "opaquePaths",
                                             "unversionedPathCount", "unversionedPaths", "noCpePathCount", "noCpePaths", "warning"}):
        raise ValueError("native coverage evidence malformed")
    derivation_outputs = evidence["derivationOutputs"]
    if not isinstance(derivation_outputs, dict):
        raise ValueError("native derivation output evidence malformed")
    for ref, outputs in derivation_outputs.items():
        store_paths([ref])
        if not ref.endswith(".drv"):
            raise ValueError("native output evidence is not a derivation")
        store_paths(outputs)

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
            if path in covered:
                raise ValueError("native output has duplicate component owners")
            if (ref.endswith(".drv") and closure[path].get("deriver") not in (None, ref)
                    and path not in derivation_outputs.get(ref, [])):
                raise ValueError("native alternative deriver lacks recorded output evidence")
            covered[path] = ref
        components[ref] = (component, outputs)
    opaque = store_paths(evidence["coverage"]["opaquePaths"])
    if opaque != paths - covered.keys():
        raise ValueError("native opaque ledger differs from unrepresented closure paths")
    for path in opaque:
        label = Path(path).name[33:]
        if closure[path].get("deriver") is not None or re.search(r"-(?:(?:git|unstable)-)?v?[0-9]", label):
            raise ValueError("missing software component cannot be opaque: " + path)
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
        if path not in covered:
            continue  # raw opaque edges remain recorded in the exact closure ledger
        expected = {covered[reference] for reference in record["references"] if reference in covered} - {covered[path]}
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
    coverage = evidence["coverage"]
    unversioned = {path for path, ref in covered.items() if not components[ref][0]["version"]}
    no_cpe = {path for path, ref in covered.items() if not components[ref][0].get("cpe")}
    if (coverage["closurePathCount"] != len(paths) or coverage["representedPathCount"] != len(covered)
            or coverage["opaquePathCount"] != len(opaque)
            or store_paths(coverage["unversionedPaths"]) != unversioned or coverage["unversionedPathCount"] != len(unversioned)
            or store_paths(coverage["noCpePaths"]) != no_cpe or coverage["noCpePathCount"] != len(no_cpe)
            or coverage["warning"] != NATIVE_WARNING):
        raise ValueError("native coverage accounting differs from the inventories")
    return coverage


def native_identity(cdx):
    """Qualify structurally valid source PURLs without rewriting their bytes."""
    derived = copy.deepcopy(cdx)
    changes, unqualified = [], []
    for component in [derived["metadata"]["component"], *derived["components"]]:
        ref = component["bom-ref"]
        drvs = [prop["value"] for prop in component["properties"] if prop["name"] == "nix:drv_path"]
        original = component.get("purl")
        if not drvs or not original:
            unqualified.append({"bomRef": ref, "reason": "no derivation" if not drvs else "no PURL"})
            continue
        if len(drvs) != 1 or not drvs[0].endswith(".drv"):
            raise ValueError("native qualifier requires one actual derivation")
        store_paths(drvs)
        if (not isinstance(original, str)
                or re.search(r"%(?![0-9A-Fa-f]{2})", original)):
            raise ValueError("native source PURL is malformed")
        base, fragment_mark, fragment = original.partition("#")
        coordinate, query_mark, query = base.partition("?")
        if (not re.fullmatch(r"pkg:[A-Za-z][A-Za-z0-9.+-]*/[^/?#@\s]+(?:/[^/?#@\s]+)*(?:@[^/?#@\s]+)?", coordinate)
                or (query_mark and not query)):
            raise ValueError("native source PURL coordinates or qualifiers are absent")
        keys = set()
        qualifiers = parse_qsl(query, keep_blank_values=True, strict_parsing=True, errors="strict") if query else ()
        for key, value in qualifiers:
            key = key.lower()
            if (not re.fullmatch(r"[a-z][a-z0-9._-]*", key)
                    or not value or key == "nix_drv" or key in keys):
                raise ValueError("native source PURL qualifiers are invalid or already qualified")
            keys.add(key)
        qualified = coordinate + "?" + (query + "&" if query_mark and query else "") + "nix_drv=" + quote(drvs[0], safe="")
        if fragment_mark:
            qualified += "#" + fragment
        component["purl"] = qualified
        changes.append({"bomRef": ref, "drvPath": drvs[0], "originalPurl": original, "derivedPurl": qualified})
    return derived, changes, unqualified


def native_identity_receipt(directory, provenance, changes, unqualified):
    return {
        "transformation": "nix_drv-purl-v1",
        "root": {"drvPath": provenance["drvPath"], "outPath": provenance["outPath"]},
        "source": {"file": "native.cdx.json", "sha256": digest(directory / "native.cdx.json")},
        "derived": {"file": "native-identity.cdx.json", "sha256": digest(directory / "native-identity.cdx.json")},
        "changes": changes, "unqualified": unqualified,
    }


def record_native_identity(directory, provenance):
    derived, changes, unqualified = native_identity(json.loads((directory / "native.cdx.json").read_text()))
    (directory / "native-identity.cdx.json").write_text(json.dumps(derived, indent=2) + "\n")
    receipt = native_identity_receipt(directory, provenance, changes, unqualified)
    (directory / "native-identity.provenance.json").write_text(json.dumps(receipt, indent=2) + "\n")


def verify_native_identity(directory, provenance):
    derived, changes, unqualified = native_identity(json.loads((directory / "native.cdx.json").read_text()))
    if (json.loads((directory / "native-identity.cdx.json").read_text()) != derived
            or json.loads((directory / "native-identity.provenance.json").read_text())
            != native_identity_receipt(directory, provenance, changes, unqualified)):
        raise ValueError("native derived inventory or transformation provenance mismatch")


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
    required = {"native.cdx.json", "native.csv", "closure.json", "native-evidence.json", "native-identity.cdx.json", "native-identity.provenance.json"} if provenance["kind"] == "nix" else set()
    if provenance.get("ociArchive"):
        required.add("archive.cdx.json")
    if not required <= set(manifest["files"]):
        raise ValueError("kind-specific inventory files absent: " + ", ".join(sorted(required - set(manifest["files"]))))
    if provenance["kind"] == "nix":
        native_coverage(directory, provenance)
        verify_native_identity(directory, provenance)
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
