#!/usr/bin/env python3
"""Inventory orchestration only: sbomnix/vulnxscan and Trivy own detection/SARIF.

plan evaluates declarations; collect produces immutable reusable inventories;
scan refreshes advisory data without evaluating, building, or contacting hosts.
"""
import argparse
import copy
from datetime import datetime, timezone
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import tarfile

# Imports must not write mutable bytecode into the flake being fingerprinted.
sys.dont_write_bytecode = True

import security_artifacts

SBOMNIX = "6bdd2a62d23a19ea96ac480ac9df9f5c5626aa13"

SCHEMA = 1


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def capture(*args):
    return run(*args, stdout=subprocess.PIPE).stdout


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + "\n")


def identity(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24]


def stage_file(source, destination):
    try:
        os.link(source, destination)
        return destination
    except OSError as error:
        if error.errno not in (errno.EPERM, errno.EXDEV):
            raise
        # Linux protected_hardlinks rejects unprivileged links to root-owned
        # store files; a different staging filesystem also requires a copy.
        return shutil.copy2(source, destination)


def images(value, pointer=""):
    """Image references plus stable declaration slots, not version-based alert IDs."""
    if isinstance(value, dict):
        for key, child in value.items():
            location = pointer + "/" + key
            if key == "image" and isinstance(child, str):
                yield child, location
            else:
                yield from images(child, location)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            slot = child.get("name", index) if isinstance(child, dict) else index
            yield from images(child, pointer + "/" + str(slot))


def source_metadata():
    # path:. in an external JJ workspace includes mutable VCS/bytecode files.
    # Canonicalize only those non-source directories, so controller/native
    # checkouts share an identity without relying on an enclosing Git repository.
    snapshot = capture("nix", "eval", "--raw", "--impure", "--option",
        "allow-import-from-derivation", "false", "--expr",
        'builtins.toString (builtins.path { path = ./.; name = "security-source"; '
        'filter = path: _: !(builtins.elem (builtins.baseNameOf path) [ ".git" ".jj" "__pycache__" ]); })').strip()
    metadata = json.loads(capture("nix", "flake", "metadata", "--json", "--no-write-lock-file", "path:" + snapshot))
    if not re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", metadata["locked"]["narHash"]):
        raise ValueError("working flake has no immutable source NAR identity")
    if not metadata["path"].startswith("/nix/store/"):
        raise ValueError("working flake was not materialized as an immutable source")
    return metadata


def inventory_key(row):
    implementation = identity(security_artifacts.digest(Path(__file__)) + security_artifacts.digest(Path(security_artifacts.__file__)))
    artifact = [row["drvPath"], row["outPath"]] if row["kind"] == "nix" else [row["resolvedImage"], row["ociPlatform"]]
    return identity(json.dumps([SCHEMA, SBOMNIX, implementation, row["system"], artifact]))


def resolve_row(descriptor):
    row = dict(descriptor)
    metadata = source_metadata()
    if row["plannedSourceNarHash"] != metadata["locked"]["narHash"]:
        raise ValueError("planned entry does not match the current working source")
    if row["kind"] == "nix":
        executor = capture("nix", "eval", "--raw", "--impure", "--expr", "builtins.currentSystem").strip()
        if executor != row["system"]:
            raise ValueError("Nix target resolution requires its matching native executor")
        # Nix JSON coerces an attrset containing outPath to a string.
        selected = json.loads(capture("nix", "eval", "--json", f"path:{metadata['path']}#{row['target']}",
            "--apply", 'package: assert (package.type or null) == "derivation"; { inherit (package) drvPath; outputPath = package.outPath; }'))
        row.update(drvPath=selected["drvPath"], outPath=selected["outputPath"])
    row["sourcePath"] = metadata["path"]
    row["sourceNarHash"] = metadata["locked"]["narHash"]
    row["inventoryKey"] = inventory_key(row)
    return row


def resolve(args):
    row = resolve_row(json.loads(Path(args.entry).read_text()))
    save(args.output, row)
    if args.github_output:
        with open(args.github_output, "a") as stream:
            stream.write("inventoryKey=" + row["inventoryKey"] + "\n")


def current_entry(path):
    row = json.loads(Path(path).read_text())
    metadata = source_metadata()
    if row["sourceNarHash"] != metadata["locked"]["narHash"] or row["plannedSourceNarHash"] != row["sourceNarHash"]:
        raise ValueError("resolved entry is stale relative to the working source")
    if row["sourcePath"] != metadata["path"] or row["inventoryKey"] != inventory_key(row):
        raise ValueError("resolved artifact/source/tool identity mismatch")
    return row


def verify_build_output(row, built_json):
    if (len(built_json) != 1 or built_json[0]["drvPath"] != row["drvPath"]
            or row["outPath"] not in built_json[0]["outputs"].values()):
        raise ValueError("built output does not match the resolved inventory identity")


def image_reference(image):
    name, separator, pinned = image.partition("@")
    repository = name.rsplit(":", 1)[0] if ":" in name.rsplit("/", 1)[-1] else name
    if separator:
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", pinned):
            raise ValueError("declared OCI digest is not a valid sha256 identity")
        # Kubernetes accepts tag@digest; Skopeo requires the authoritative
        # digest-only form. Preserve the full original declaration in inventory.
        return repository, repository + "@" + pinned
    return repository, image


def plan(args):
    metadata = source_metadata()
    source = Path(metadata["path"])
    inventory = json.loads(capture("nix", "eval", "--json", "--option",
                                   "allow-import-from-derivation", "false", f"path:{source}#securityInventory"))
    planned_source = metadata["locked"]["narHash"]
    entries, unsupported, seen_images, manifest_platforms = [], [], {}, {}
    for system, platform in inventory.items():
        for row in platform["roots"]:
            row["id"] = identity(row["target"])
            row["location"] = "flake.lock"
            if platform["nativeSupported"]:
                entries.append(row)
            else:
                unsupported.append(dict(row, reason="sbomnix/flakevuln qualification is Linux-only"))
        for manifest in platform.get("manifests", []):
            manifest_platforms[manifest["source"]] = manifest["platform"]
        for row in platform["images"]:
            seen_images.setdefault((row["image"], system), dict(row, location="modules/flake/security-inventory.nix"))
    # This is the same committed renderer inventory checked by *-manifests-fresh;
    # it is referenced source, NOT proof of a live cluster or fresh rendering.
    for document_path in sorted((source / "generated/manifests").rglob("*.yaml")):
        path = document_path.relative_to(source)
        documents = json.loads(capture("yq", "eval-all", "-o=json", "[.]", str(document_path)))
        system = manifest_platforms.get(str(Path(*path.parts[:3])))
        for document in documents:
            for image, pointer in images(document):
                row = seen_images.setdefault((image, system), {
                    "kind": "oci", "image": image, "state": "referenced",
                    "source": str(path), "location": str(path), "pointer": pointer, "system": system,
                    "update": "owning image/chart declaration under modules/den/aspects/kubernetes; regenerate manifests",
                })
                row.setdefault("references", []).append(str(path))
    for (image, system), row in sorted(seen_images.items(), key=lambda item: str(item[0])):
        row["id"] = identity(f"{row['source']}:{row.get('pointer', '')}:{system}")
        if not isinstance(image, str) or not image:
            unsupported.append(dict(row, reason="OCI declaration has no image reference"))
            continue
        if system not in ("x86_64-linux", "aarch64-linux"):
            unsupported.append(dict(row, reason="OCI platform is not a declared supported Linux platform"))
            continue
        row["ociPlatform"] = "linux/arm64" if system == "aarch64-linux" else "linux/amd64"
        if image.startswith(("localhost/", "localhost:")):
            unsupported.append(dict(row, reason="local OCI image unavailable from a registry; scan its published digest or OCI archive explicitly"))
            continue
        try:
            repository, reference = image_reference(image)
            architecture = "arm64" if system == "aarch64-linux" else "amd64"
            digest = capture("skopeo", "--override-os", "linux", "--override-arch", architecture,
                             "inspect", "--no-creds", "--format", "{{.Digest}}", "docker://" + reference).strip()
            if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
                raise ValueError("registry did not return a valid sha256 digest")
            if "@" in reference and digest != reference.rsplit("@", 1)[1]:
                raise ValueError("registry digest does not match the declared immutable image")
            row["resolvedImage"] = repository + "@" + digest
            entries.append(row)
        except (subprocess.CalledProcessError, ValueError) as error:
            unsupported.append(dict(row, inventoryFailure=True, reason="OCI digest resolution failed: " + str(error)))
    for row in entries:
        row["plannedSourceNarHash"] = planned_source
        row["runner"] = "ubuntu-26.04-arm" if row["system"] == "aarch64-linux" else "ubuntu-26.04"
    result = {"schema": SCHEMA, "entries": entries, "unsupported": unsupported,
              "deployed": {"status": "unobserved"}}
    save(args.output, result)
    if args.github_output:
        with open(args.github_output, "a") as stream:
            stream.write("matrix=" + json.dumps({"include": entries}, separators=(",", ":")) + "\n")
    print(f"{len(entries)} scan targets; {len(unsupported)} unsupported targets; see {args.output}")


def collect(args):
    row = current_entry(args.entry)
    directory = Path(args.directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    provenance = dict(row, schema=SCHEMA, collectedAt=datetime.now(timezone.utc).isoformat(),
                      sourceRevision=os.environ.get("GITHUB_SHA"), sbomnix=SBOMNIX,
                      trivyVersion=capture("trivy", "--config", "", "--version"))
    # Cache only complete inventories. Findings/databases are never cached here.
    if (directory / "complete.json").exists():
        security_artifacts.verify(directory, row["inventoryKey"], entry=row)
        original = json.loads((directory / "provenance.json").read_text())
        save(directory / "provenance.json", dict(original, reused=True,
             source=row.get("source"), location=row.get("location"), update=row.get("update"),
             requestedSourceNarHash=row["sourceNarHash"],
             requestedByRevision=provenance["sourceRevision"], requestedAt=provenance["collectedAt"]))
        security_artifacts.seal(directory, row["inventoryKey"])
        return
    if row["kind"] == "nix":
        built = json.loads(capture("nix", "build", "--no-link", "--json", f"path:{row['sourcePath']}#{row['target']}"))
        verify_build_output(row, built)
        root = Path(row["outPath"])
        if root.is_file() and tarfile.is_tarfile(root):
            with tarfile.open(root) as archive:
                is_image = any(member.name.lstrip("./") in ("manifest.json", "index.json") for member in archive)
            if is_image:
                run("trivy", "--config", "", "image", "--ignorefile", "", "--input", str(root),
                    "--format", "cyclonedx", "--output", str(directory / "archive.cdx.json"))
                provenance["ociArchive"] = str(root)
        closure = json.loads(capture("nix", "path-info", "--json", "--json-format", "1", "--recursive", row["outPath"]))
        save(directory / "closure.json", closure)
        closure_bytes = sum(record["narSize"] for record in closure.values())
        staging_bytes = sum(record["narSize"] for path, record in closure.items() if path != provenance.get("ociArchive"))
        temporary_parent = args.staging_directory or tempfile.gettempdir()
        free_bytes = shutil.disk_usage(temporary_parent).free
        if args.reserve_bytes < 0:
            raise ValueError("--reserve-bytes must be nonnegative")
        print(f"Reference closure: {len(closure)} paths, {closure_bytes} NAR bytes already realized; "
              f"staging budget: {staging_bytes} bytes, free: {free_bytes}, reserve: {args.reserve_bytes}")
        if free_bytes < staging_bytes + args.reserve_bytes:
            raise OSError(errno.ENOSPC, "insufficient staging disk for full closure plus requested reserve; choose --staging-directory or provision the runner")
        provenance["closureNarBytes"] = closure_bytes
        provenance["stagingBudgetBytes"] = staging_bytes
        run("sbomnix", f"path:{row['sourcePath']}#{row['target']}", "--require-cpe-dictionary",
            "--cdx", str(directory / "native.cdx.json"), "--csv", str(directory / "native.csv"), "--spdx", "")
        security_artifacts.record_native_evidence(directory, provenance,
            lambda ref: capture("nix-store", "--query", "--outputs", ref).splitlines())
        # Trivy does not follow Nix references or symlinks. Present every exact
        # reference as ordinary directories, preserving symlinks but not following
        # them. Prefer hardlinks; protected store files/cross-device staging
        # require temporary copies. Never scan the entire store.
        with tempfile.TemporaryDirectory(dir=args.staging_directory) as temporary:
            for path in closure:
                if path == provenance.get("ociArchive"):
                    continue  # already inventoried directly as an OCI archive
                source = Path(path)
                destination = Path(temporary) / source.name
                if source.is_symlink():
                    destination.symlink_to(os.readlink(source))
                elif source.is_dir():
                    shutil.copytree(source, destination, symlinks=True, copy_function=stage_file)
                else:
                    stage_file(source, destination)
            # rootfs, not filesystem: upstream fs mode omits compiled Go binaries.
            run("trivy", "--config", "", "rootfs", "--ignorefile", "", "--format", "cyclonedx",
                "--output", str(directory / "language.cdx.json"), temporary)
        provenance["state"] = "built"
        provenance["references"] = list(closure)
    else:
        run("trivy", "--config", "", "image", "--image-src", "remote", "--ignorefile", "", "--platform", row["ociPlatform"],
            "--format", "cyclonedx", "--output", str(directory / "language.cdx.json"), row["resolvedImage"])
        provenance["state"] = "referenced"
    save(directory / "provenance.json", provenance)
    security_artifacts.seal(directory, row["inventoryKey"])


def project_sarif(sarif, row, inventory_path=None):
    """Attribute inventory findings without impersonating source-line hashes."""
    for sarif_run in sarif["runs"]:
        rules = sarif_run["tool"]["driver"]["rules"]
        originals = {rule["id"]: rule for rule in rules}
        projected = {}
        for finding in sarif_run.get("results", []):
            original = finding.get("locations", [])
            properties = finding.setdefault("properties", {})
            rule_id = finding["ruleId"]
            if inventory_path is None:
                component = [properties["package"], properties["version"]]
            else:
                # Trivy OS results name the input SBOM, not an installed file.
                # Its staging prefix must not become part of component identity.
                component = [
                    [location["physicalLocation"]["artifactLocation"]["uri"],
                     location.get("message", {}).get("text", "")]
                    for location in original]
                component = [[value.replace(str(inventory_path), inventory_path.name)
                              for value in location] for location in component]
            semantic = hashlib.sha256(json.dumps(
                [row["id"], rule_id, component], sort_keys=True).encode()).hexdigest()
            # GitHub ignores custom partial keys. Qualify the rule instead so
            # same-CVE components at one declaration remain separate alerts.
            qualified = rule_id + "/component/" + semantic
            if qualified not in projected:
                rule = copy.deepcopy(originals[rule_id])
                rule["id"] = qualified
                rule.setdefault("properties", {})["inventoryRuleId"] = rule_id
                projected[qualified] = len(rules)
                rules.append(rule)
            finding["ruleId"] = qualified
            finding["ruleIndex"] = projected[qualified]
            properties["inventoryRuleId"] = rule_id
            properties["inventoryLocations"] = original
            properties["inventoryFingerprints"] = {
                key: finding.pop(key) for key in ("fingerprints", "partialFingerprints") if key in finding}
            locations = ([properties["package"] + "@" + properties["version"]] if inventory_path is None else
                         [location.get("message", {}).get("text", "") for location in original])
            finding["message"]["text"] += "\nInventory component: " + "; ".join(filter(None, locations))
            finding["locations"] = [{"physicalLocation": {
                "artifactLocation": {"uri": row["location"]}, "region": {"startLine": 1}}}]
    return sarif


def scan(args):
    directory = Path(args.directory).resolve()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    row = json.loads((directory / "provenance.json").read_text())
    security_artifacts.verify(directory, row["inventoryKey"])
    if row["kind"] == "nix":
        row["nativeCoverage"] = json.loads((directory / "native-evidence.json").read_text())["coverage"]
        # Ignore source-local scanner configuration, not vulnerability findings.
        policy = output / "grype-policy.yaml"
        save(policy, {"ignore": []})
        os.environ.update(GRYPE_CONFIG=str(policy), GRYPE_DB_AUTO_UPDATE="true",
                          GRYPE_DB_REQUIRE_UPDATE_CHECK="true")
        run("grype", "db", "update")
        with (output / "grype-db.json").open("w") as stream:
            run("grype", "db", "status", "--output", "json", stdout=stream)
        # OSV has no Nix ecosystem; cross-ecosystem bare-name queries are not
        # identity evidence. Keep language-aware OSV in the existing Go audit.
        run("vulnxscan", "--sbom", str(directory / "native.cdx.json"), "--skip-osv",
            "--format", "sarif", "--out", str(output / "native.sarif"),
            "--evidence-out", str(output / "native-evidence.json"),
            "--sarif-location", row["location"])
        path = output / "native.sarif"
        save(path, project_sarif(json.loads(path.read_text()), row))
    for name in ("language", "archive"):
        sbom = directory / f"{name}.cdx.json"
        if not sbom.exists():
            continue
        run("trivy", "--config", "", "sbom", "--ignorefile", "", "--format", "json",
            "--output", str(output / f"{name}.json"), str(sbom))
        run("trivy", "--config", "", "convert", "--format", "sarif",
            "--output", str(output / f"{name}.sarif"), str(output / f"{name}.json"))
        path = output / f"{name}.sarif"
        save(path, project_sarif(json.loads(path.read_text()), row, sbom))
    save(output / "provenance.json", dict(row, advisoryRefreshAt=datetime.now(timezone.utc).isoformat(),
        nativeRefresh="Grype CPE matching; no Nix-unsupported OSV, Vulnix or patch applicability suppression",
        trivyDatabase=capture("trivy", "--config", "", "--version"),
        deployed="unobserved"))
    summary = f"### Security inventory `{row['id']}`\n\nSource: `{row['source']}`\n\nArtifact: `{row.get('outPath', row.get('resolvedImage'))}`\n\nUpdate owner: {row['update']}\n\nBuilt/referenced is not deployed. Native matches are candidates, not reachability or backport verdicts. Reusable native scans omit Vulnix/patch suppression; inspect native.csv and evidence before dismissal. Trivy is complementary language/OCI coverage, not native Nix matching. Full findings, fixed-version hints, inventory and database provenance are attached as artifacts.\n"
    if row["kind"] == "nix":
        coverage = row["nativeCoverage"]
        summary += (f"\nComposite native closure: {coverage['closurePathCount']} paths; "
                    f"{coverage['representedPathCount']} represented by upstream components; "
                    f"{coverage['opaquePathCount']} opaque raw paths; "
                    f"{coverage['unversionedPathCount']} represented paths without versions; "
                    f"{coverage['noCpePathCount']} represented paths without CPEs. "
                    f"{coverage['warning']} Exact affected paths are in inventory/native-evidence.json.\n")
    (output / "summary.md").write_text(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("plan")
    p.add_argument("--output", default="security-plan.json")
    p.add_argument("--github-output")
    p = commands.add_parser("resolve")
    p.add_argument("--entry", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--github-output")
    p = commands.add_parser("restore")
    p.add_argument("--entry", required=True)
    p.add_argument("--directory", required=True)
    p.add_argument("--repository", required=True)
    p.add_argument("--branch", required=True)
    p = commands.add_parser("collect")
    p.add_argument("--entry", required=True)
    p.add_argument("--directory", required=True)
    p.add_argument("--staging-directory", help="writable temporary directory; allow closure-sized disk if hardlinks are unavailable")
    p.add_argument("--reserve-bytes", type=int, default=2 * 1024**3, help="free disk to retain after worst-case staging copies (default 2 GiB)")
    p = commands.add_parser("scan")
    p.add_argument("--directory", required=True)
    p.add_argument("--output", required=True)
    args = parser.parse_args()
    if args.command == "restore":
        security_artifacts.restore(current_entry(args.entry), Path(args.directory), args.repository, args.branch)
    else:
        {"plan": plan, "resolve": resolve, "collect": collect, "scan": scan}[args.command](args)


if __name__ == "__main__":
    main()
