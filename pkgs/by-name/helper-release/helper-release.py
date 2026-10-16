#!/usr/bin/env python3
"""Build read-only helper candidates, publish fixed identities, verify anonymously."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

HELPERS = ("retained-directories-image", "kanidm-provision-image", "jellyfin-provisioner-image", "jellarr-image")
ARCHITECTURES = {"x86_64-linux": "amd64", "aarch64-linux": "arm64"}
PREFIX = "ghcr.io/dvicory/homelab"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, parsed=False):
    if args[0] == "skopeo":
        args = ("skopeo", "--policy", os.environ["HELPER_RELEASE_POLICY"], *args[1:])
    value = subprocess.run(args, check=True, stdout=subprocess.PIPE).stdout
    return json.loads(value) if parsed else value


def sha(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save(path, value):
    # Refused candidates cannot replace a previously verified selection.
    path = Path(path)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
    os.replace(temporary, path)


def image_config(reference, anonymous=False):
    flags = (["--tls-verify=true"] if reference.startswith("docker://") else []) + (["--no-creds"] if anonymous else [])
    raw = run("skopeo", "inspect", *flags, "--config", "--raw", reference)
    config = json.loads(raw)
    return {"configDigest": "sha256:" + hashlib.sha256(raw).hexdigest(), "os": config["os"], "architecture": config["architecture"], "rootfs": config["rootfs"]}

def audit_bytes(data):
    require(not re.search(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----\r?\n[A-Za-z0-9+/=\r\n]{32,}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}", data), "private key or credential candidate in public image")


def audit_metadata(value):
    if isinstance(value, str):
        audit_bytes(value.encode())
    elif isinstance(value, dict):
        for key, item in value.items():
            audit_metadata(key)
            audit_metadata(item)
    elif isinstance(value, list):
        for item in value:
            audit_metadata(item)



def audit(archive):
    """Inspect layers and metadata without extraction; public PEMs are allowed."""
    count = 0
    payload_files = 0
    with tarfile.open(archive) as outer:
        manifest = json.load(outer.extractfile("manifest.json"))
        layers = {name for image in manifest for name in image["Layers"]}
        require(layers, "image has no referenced layers")
        require(all(outer.getmember(name).isfile() for name in layers), "referenced layers must be regular archive members")
        for layer in outer:
            audit_metadata(layer.get_info())
            audit_metadata(layer.pax_headers)
            name = layer.name.removeprefix("./")
            require(not any(part in (".secrets", ".ssh", ".aws") for part in Path(name).parts), "private credential path in public image")
            require(not name.endswith(".age"), "encrypted production secret in public image")
            if not layer.isfile():
                continue
            if layer.name not in layers and not layer.name.endswith(".tar"):
                data = outer.extractfile(layer).read()
                audit_bytes(data)
                try:
                    metadata = json.loads(data)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    pass
                else:
                    audit_metadata(metadata)
                count += 1
                continue
            with tarfile.open(fileobj=outer.extractfile(layer)) as payload:
                for member in payload:
                    audit_metadata(member.get_info())
                    audit_metadata(member.pax_headers)
                    name = member.name.removeprefix("./")
                    require(not any(part in (".secrets", ".ssh", ".aws") for part in Path(name).parts), "private credential path in public image")
                    require(not name.endswith(".age"), "encrypted production secret in public image")
                    if member.isfile():
                        with payload.extractfile(member) as stream:
                            previous = b""
                            while chunk := stream.read(1024 * 1024):
                                data = previous + chunk
                                audit_bytes(data)
                                previous = data[-4096:]
                        count += 1
                        payload_files += 1
    require(payload_files > 0, "image has no audited payload")
    return count


def build(args):
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_sha), "source SHA must be immutable")
    directory = Path(args.directory)
    directory.mkdir(parents=True, exist_ok=False)
    metadata = run("nix", "flake", "metadata", "--json", "--no-write-lock-file", args.source, parsed=True)
    require(metadata["locked"].get("rev") == args.source_sha, "Nix source differs from authorized SHA")
    names = args.helpers or HELPERS
    # Query the existing producers directly, not a second source/lock convention.
    expression = "packages: { " + " ".join(
        f'"{name}" = {{ derivation = packages."{name}".drvPath; archivePath = toString packages."{name}"; }};'
        for name in names
    ) + " }"
    inventory = run("nix", "eval", "--json", "--no-write-lock-file", "--apply", expression, f"{args.source}#packages.{args.system}", parsed=True)
    entries = {}
    for name in names:
        producer = inventory[name]
        output = run("nix", "build", "--no-link", "--print-out-paths", "--no-write-lock-file", f"{args.source}#packages.{args.system}.{name}").decode().strip()
        require(output == producer["archivePath"], "built archive differs from declared Nix producer")
        require(re.fullmatch(r"/nix/store/[0-9a-z]{32}-[^/]+\.drv", producer["derivation"]), "invalid producer derivation identity")
        require(re.fullmatch(r"/nix/store/[0-9a-z]{32}-[^/]+", output), "invalid producer output identity")
        # Transfer artifact, not a second retained release store.
        target = directory / f"{name}.tar"
        with open(output, "rb") as source, target.open("xb") as destination:
            shutil.copyfileobj(source, destination)
        identity = image_config(f"docker-archive:{target}")
        require(identity["os"] == "linux" and identity["architecture"] == ARCHITECTURES[args.system], "producer has wrong native platform")
        entries[name] = dict(producer, **identity, archiveSha256=sha(target), auditedFiles=audit(target))
    save(directory / "candidate.json", {"schema": 1, "sourceSha": args.source_sha, "sourceRun": args.source_run, "sourceNarHash": metadata["locked"]["narHash"], "system": args.system, "artifacts": entries})
    print(sha(directory / "candidate.json"))


def candidate(args):
    directory = Path(args.directory)
    require(not directory.is_symlink() and all(path.is_file() and not path.is_symlink() for path in directory.iterdir()), "transfer must contain regular files only")
    require(sha(directory / "candidate.json") == args.candidate_sha256, "artifact metadata differs from trusted read-only build")
    value = json.loads((directory / "candidate.json").read_text())
    require(value["schema"] == 1 and value["sourceSha"] == args.source_sha and value["sourceRun"] == args.source_run, "artifact source SHA/run does not match authorized source")
    require(value["system"] == args.system, "artifact target platform mismatch")
    names = set(value["artifacts"])
    require(names == set(HELPERS) or (args.disposable and names and names <= set(HELPERS)), "artifact inventory differs from fixed helper allowlist")
    require({p.name for p in directory.iterdir()} <= {"candidate.json", "publication.json"} | {f"{name}.tar" for name in names}, "unexpected transfer artifact contents")
    for name, identity in value["artifacts"].items():
        require(re.fullmatch(r"/nix/store/[0-9a-z]{32}-[^/]+\.drv", identity["derivation"]), "invalid producer derivation identity")
        require(re.fullmatch(r"/nix/store/[0-9a-z]{32}-[^/]+", identity["archivePath"]), "invalid producer output identity")
        archive = directory / f"{name}.tar"
        require(sha(archive) == identity["archiveSha256"], "altered transfer archive")
        require(image_config(f"docker-archive:{archive}") == {key: identity[key] for key in ("configDigest", "os", "architecture", "rootfs")}, "altered producer config/rootfs identity")
        require(identity["os"] == "linux" and identity["architecture"] == ARCHITECTURES[args.system], "artifact native platform mismatch")
        audit(archive)
    return value


def remote(repository, digest, anonymous):
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", digest), "missing or invalid manifest digest")
    reference = f"docker://{repository}@{digest}"
    flags = ["--tls-verify=true"] + (["--no-creds"] if anonymous else [])
    raw = run("skopeo", "inspect", *flags, "--raw", reference)
    require("sha256:" + hashlib.sha256(raw).hexdigest() == digest, "remote manifest digest mismatch")
    manifest = json.loads(raw)
    require("manifests" not in manifest, "unverified multiarch index is not a native release")
    config = image_config(reference, anonymous=anonymous)
    require(manifest["config"]["digest"] == config["configDigest"], "remote config digest mismatch")
    return config


def publish(args):
    require(args.disposable or args.prefix == PREFIX, "unapproved publication namespace")
    value = candidate(args)
    entries = {}
    for name, identity in value["artifacts"].items():
        repository = f"{args.prefix}/{name.removesuffix('-image')}"
        # Only a publication handle. Consumers never select this mutable tag.
        handle = f"{repository}:candidate-{args.source_sha}-{identity['archiveSha256']}"
        with tempfile.TemporaryDirectory() as temporary:
            digest_file = Path(temporary) / "digest"
            # OCI conversion rewrites Docker creation/history timestamps. GHCR
            # and K3s support schema 2; preserve the producer's exact config bytes.
            run("skopeo", "copy", "--dest-tls-verify=true", "--format", "v2s2", "--digestfile", str(digest_file), f"docker-archive:{Path(args.directory) / (name + '.tar')}", f"docker://{handle}")
            digest = digest_file.read_text().strip()
        require(remote(repository, digest, anonymous=False) == {key: identity[key] for key in ("configDigest", "os", "architecture", "rootfs")}, "published artifact differs from original producer")
        entries[name] = dict(identity, repository=repository, digest=digest)
    save(Path(args.directory) / "publication.json", dict(value, artifacts=entries))


def verify(args):
    original = candidate(args)
    publication = json.loads((Path(args.directory) / "publication.json").read_text())
    require({key: publication[key] for key in original if key != "artifacts"} == {key: original[key] for key in original if key != "artifacts"}, "publication source differs from candidate")
    require(set(publication["artifacts"]) == set(original["artifacts"]), "publication inventory mismatch")
    selected = {}
    for name, identity in publication["artifacts"].items():
        source = original["artifacts"][name]
        require(all(identity[key] == value for key, value in source.items()), "publication producer identity mismatch")
        require(args.disposable or identity["repository"] == f"{PREFIX}/{name.removesuffix('-image')}", "unapproved consumer repository")
        require(remote(identity["repository"], identity["digest"], anonymous=True) == {key: source[key] for key in ("configDigest", "os", "architecture", "rootfs")}, "anonymous artifact differs from declared producer")
        with tempfile.TemporaryDirectory() as temporary:
            run("skopeo", "copy", "--src-no-creds", "--src-tls-verify=true", "--preserve-digests", f"docker://{identity['repository']}@{identity['digest']}", f"dir:{temporary}/image")
        selected[name] = identity
    # Explicit candidate output only: never commit, update a host or activate GitOps.
    save(args.output, {"schema": 1, "sourceSha": args.source_sha, "sourceRun": args.source_run, "system": args.system, "artifacts": selected})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("build", "publish", "verify"):
        item = sub.add_parser(command)
        item.add_argument("--directory", required=True)
        item.add_argument("--source-sha", required=True)
        item.add_argument("--source-run", required=True, type=int)
        item.add_argument("--system", choices=ARCHITECTURES, required=True)
        item.add_argument("--disposable", action="store_true", help="test-only source/namespace/subset exception; never enabled by CI publisher")
        if command == "build":
            item.add_argument("--source", required=True)
            item.add_argument("--helpers", nargs="+", choices=HELPERS)
        else:
            item.add_argument("--candidate-sha256", required=True, help="fingerprint recorded by the trusted read-only build, not from artifact metadata")
        if command == "publish":
            item.add_argument("--prefix", default=PREFIX)
        if command == "verify":
            item.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        require(args.source_run > 0 and re.fullmatch(r"[0-9a-f]{40}", args.source_sha), "invalid authorized source identity")
        {"build": build, "publish": publish, "verify": verify}[args.command](args)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        parser.exit(1, f"helper-release: {error}\n")


if __name__ == "__main__":
    main()
