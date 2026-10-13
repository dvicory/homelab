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

spec = importlib.util.spec_from_file_location("helper_release", sys.argv[1])
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def image(path, filename, payload, metadata=None, layer_name="layer.tar"):
    layers = {}
    for name, filename, payload in (
        (layer_name, filename, payload),
        ("control.tar", "usr/share/audit-control", b"public control"),
    ):
        layer = io.BytesIO()
        with tarfile.open(fileobj=layer, mode="w") as archive:
            item = tarfile.TarInfo(filename)
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
print("real private keys in layer/config, encrypted inputs and credential paths in manifest-selected layers refused")
