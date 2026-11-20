"""Run with python3 -B test_policy.py; no Kubernetes or fake client."""
from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory

from lifecycle import Run, helper_logs
import registry


def check():
    target = "helper-pod-create-pvc-a"
    other = "helper-pod-create-pvc-b"
    denial = "DENIED: ownership collision or new PVC UID: explicit adoption required"
    valid = f"Start of {target} logs\n{denial}\nEnd of {target} logs\n"
    assert [body.strip() for body in helper_logs(valid, target)] == [denial]

    # The anonymous denial could belong to the already-open foreign helper.
    nested = f"Start of {other} logs\n{valid}End of {other} logs\n"
    assert list(helper_logs(nested, target)) == [], "must not borrow another helper's interleaved denial"

    inner = f"Start of {target} logs\nStart of {other} logs\n{denial}\nEnd of {other} logs\nEnd of {target} logs\n"
    assert list(helper_logs(inner, target)) == []
    assert list(helper_logs(f"Start of {target} logs\n{denial}\n", target)) == []
    assert [body.strip() for body in helper_logs(nested + valid, target)] == [denial], "later independent frames remain usable"
    print("helper-frame attribution: PASS")


def check_lease():
    for revision in ("main", "v1.0", "HEAD", "abc123", None, {}, 42, "g" * 40):
        lease = {"disposable_authorized": True, "git_revision": revision, "kubectl": "kubectl"}
        try:
            Run(lease, Path("unused-events.json"))
        except RuntimeError:
            continue
        raise AssertionError(f"unresolved Git revision accepted: {revision!r}")
    print("unresolved lease revisions: DENIED")


def check_registry_uri():
    with TemporaryDirectory(prefix="psx-registry-") as temporary:
        root = Path(temporary) / "retained%23? #"
        root.mkdir()
        registry.bootstrap(root)
        metadata = root / ".registry"
        writer = registry.connect(metadata)
        writer.execute("PRAGMA user_version=73")
        writer.close()
        reader = registry.connect(metadata, readonly=True)
        try:
            assert reader.execute("PRAGMA user_version").fetchone() == (73,)
            try:
                reader.execute("PRAGMA user_version=74")
            except sqlite3.OperationalError:
                pass
            else:
                raise AssertionError("readonly registry allowed writes")
        finally:
            reader.close()
    print("literal registry path and readonly mode: PASS")


if __name__ == "__main__":
    check()
    check_lease()
    check_registry_uri()
