#!/usr/bin/env python3
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("helper_release", sys.argv[1])
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def image(path, filename, payload, metadata=None, layer_name="layer.tar", link_target=None, pax_headers=None):
    layers = {}
    for name, filename, payload in (
        (layer_name, filename, payload),
        ("control.tar", "usr/share/audit-control", b"public control"),
    ):
        layer = io.BytesIO()
        with tarfile.open(fileobj=layer, mode="w", pax_headers=pax_headers) as archive:
            item = tarfile.TarInfo(filename)
            if name == layer_name and link_target is not None:
                item.type = tarfile.SYMTYPE
                item.linkname = link_target
            else:
                item.size = len(payload)
            archive.addfile(item, io.BytesIO(payload))
        layers[name] = layer.getvalue()
    config = {
        "architecture": "amd64",
        "os": "linux",
        "rootfs": {"type": "layers", "diff_ids": ["sha256:" + hashlib.sha256(data).hexdigest() for data in layers.values()]},
    } | (metadata or {})
    manifest = [{"Config": "config.json", "RepoTags": ["disposable/audit:latest"], "Layers": list(layers)}]
    files = layers | {"config.json": json.dumps(config).encode(), "manifest.json": json.dumps(manifest).encode()}
    with tarfile.open(path, mode="w") as archive:
        for name, content in files.items():
            item = tarfile.TarInfo(name)
            item.size = len(content)
            archive.addfile(item, io.BytesIO(content))


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=disposable-audit", "-keyout", str(root / "private.pem"), "-out", str(root / "public.pem")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for layer_name in ("layer.tar", "payload"):
        image(root / "public.tar", "etc/ssl/public.pem", (root / "public.pem").read_bytes(), layer_name=layer_name)
        assert release.audit(root / "public.tar") > 0
    for label, filename, payload, layer_name in (
        ("private key", "private.pem", (root / "private.pem").read_bytes(), "layer.tar"),
        ("encrypted production path", "etc/agenix/example.age", b"encrypted input", "layer.tar"),
        ("SSH credential path", ".ssh/config", b"runtime account configuration", "layer.tar"),
        ("manifest-selected layer without tar suffix", ".aws/credentials", b"runtime account configuration", "payload"),
    ):
        image(root / "unsafe.tar", filename, payload, layer_name=layer_name)
        try:
            release.audit(root / "unsafe.tar")
        except ValueError:
            pass
        else:
            raise AssertionError(f"unsafe image accepted: {label}")
    # Config/label strings are JSON-escaped in the archive, not layer files.
    image(root / "unsafe-config.tar", "etc/ssl/public.pem", (root / "public.pem").read_bytes(),
          {"config": {"Env": ["KEY=" + (root / "private.pem").read_text()]}})
    try:
        release.audit(root / "unsafe-config.tar")
    except ValueError:
        pass
    else:
        raise AssertionError("private key in JSON config accepted")
    credential = "ghp_" + "a" * 36
    for label, filename, link_target, pax_headers in (
        ("filename", credential, None, None),
        ("symlink target", "usr/share/link", credential, None),
        ("extended tar metadata", "usr/share/public", None, {"comment": credential}),
    ):
        image(root / "unsafe-metadata.tar", filename, b"public control", layer_name="payload",
              link_target=link_target, pax_headers=pax_headers)
        try:
            release.audit(root / "unsafe-metadata.tar")
        except ValueError:
            pass
        else:
            raise AssertionError(f"credential in tar {label} accepted")
print("real private keys in layer/config, encrypted inputs and credential paths in manifest-selected layers refused")

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    for filename in ("candidate.json", "retained-directories-image.tar", "publication.json", "subdirectory"):
        directory = root / filename.replace(".", "-")
        directory.mkdir()
        if filename == "subdirectory":
            (directory / filename).mkdir()
        else:
            # A dangling link must be refused before any read or external tool.
            (directory / filename).symlink_to(root / "absent")
        try:
            release.candidate(SimpleNamespace(directory=directory, candidate_sha256="0" * 64))
        except ValueError as error:
            assert str(error) == "transfer must contain regular files only", error
        else:
            raise AssertionError(f"linked/non-file transfer accepted: {filename}")
    linked_directory = root / "linked-directory"
    linked_directory.symlink_to(root, target_is_directory=True)
    try:
        release.candidate(SimpleNamespace(directory=linked_directory, candidate_sha256="0" * 64))
    except ValueError as error:
        assert str(error) == "transfer must contain regular files only", error
    else:
        raise AssertionError("linked transfer directory accepted")
print("linked metadata, archives, publication mappings and transfer directories refused before parsing")
