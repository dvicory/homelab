#!/usr/bin/env python3
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


def image(path, filename, payload, metadata=None):
    layer = io.BytesIO()
    with tarfile.open(fileobj=layer, mode="w") as archive:
        item = tarfile.TarInfo(filename)
        item.size = len(payload)
        archive.addfile(item, io.BytesIO(payload))
    content = layer.getvalue()
    with tarfile.open(path, mode="w") as archive:
        item = tarfile.TarInfo("layer.tar")
        item.size = len(content)
        archive.addfile(item, io.BytesIO(content))
        if metadata is not None:
            content = json.dumps(metadata).encode()
            item = tarfile.TarInfo("config.json")
            item.size = len(content)
            archive.addfile(item, io.BytesIO(content))


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=disposable-audit", "-keyout", str(root / "private.pem"), "-out", str(root / "public.pem")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    image(root / "public.tar", "etc/ssl/public.pem", (root / "public.pem").read_bytes())
    assert release.audit(root / "public.tar") == 1
    for label, filename, payload in (
        ("private key", "private.pem", (root / "private.pem").read_bytes()),
        ("encrypted production path", ".secrets/example.age", b"encrypted input"),
        ("SSH credential path", ".ssh/config", b"runtime account configuration"),
        ("AWS credential path", ".aws/credentials", b"runtime account configuration"),
    ):
        image(root / "unsafe.tar", filename, payload)
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
print("public certificate accepted; real private keys in layer/config and credential paths refused")
