"""Bounded, hash-verified reuse of inventories from this workflow's main runs."""
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


def seal(directory, key):
    manifest = {"inventoryKey": key, "files": {
        path.name: {"sha256": digest(path), "size": path.stat().st_size}
        for path in directory.iterdir() if path.name in FILES
    }, "producer": {name: os.environ.get(name) for name in (
        "GITHUB_REPOSITORY", "GITHUB_WORKFLOW_REF", "GITHUB_REF", "GITHUB_EVENT_NAME", "GITHUB_SHA")}}
    if sum(record["size"] for record in manifest["files"].values()) > MAX_EXPANDED:
        raise ValueError("inventory exceeds reusable artifact size limit")
    (directory / "complete.json").write_text(json.dumps(manifest, indent=2) + "\n")
    verify(directory, key)


def verify(directory, key, producer=None):
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
    if provenance["kind"] not in ("nix", "oci"):
        raise ValueError("unsupported inventory kind")
    required = {"native.cdx.json", "native.csv", "closure.json"} if provenance["kind"] == "nix" else set()
    if provenance.get("ociArchive"):
        required.add("archive.cdx.json")
    if not required <= set(manifest["files"]):
        raise ValueError("kind-specific inventory files absent: " + ", ".join(sorted(required - set(manifest["files"]))))
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
            verify(directory, entry["inventoryKey"], producer)
            provenance = json.loads((directory / "provenance.json").read_text())
            for field in ("id", "kind", "system", "outPath", "resolvedImage"):
                if provenance.get(field) != entry.get(field):
                    raise ValueError("cached artifact declaration mismatch: " + field)
        print(f"Reused verified inventory artifact {artifact['id']} from {sha}")
        return
    print("No matching trusted inventory; collect will realize the declared artifact")
