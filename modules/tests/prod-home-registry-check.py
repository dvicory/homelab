"""Run directly with the recovery driver path; no cluster or production state."""
import importlib.util
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("recovery", sys.argv[1])
recovery = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = recovery
spec.loader.exec_module(recovery)

# Exercise real signal delivery and elapsed grace without spending the production
# 30-second bound on each TERM-resistant child. Keep the graceful child real too.
recovery._BOOTSTRAP_STOP_GRACE = 3


def pods(reason, message, namespace="argocd", deleting=False):
    return {"items": [{"metadata": {"namespace": namespace, "deletionTimestamp": "retiring" if deleting else None},
                       "status": {"containerStatuses": [{"state": {"waiting": {"reason": reason, "message": message}}}]}}]}


assert recovery.registry_pull_failure(pods("ErrImagePull", "429 TooManyRequests")) == "rate-limited"
assert recovery.registry_pull_failure(pods("ImagePullBackOff", "unauthorized")) == "unauthorized"
assert recovery.registry_pull_failure(pods("ErrImagePull", "manifest unknown")) == "manifest-not-found"
assert recovery.registry_pull_failure(pods("ErrImagePull", "x509: certificate expired")) == "certificate"
assert recovery.registry_pull_failure(pods("CrashLoopBackOff", "429 TooManyRequests")) is None
assert recovery.registry_pull_failure(pods("ErrImagePull", "429 TooManyRequests", namespace="other")) is None
assert recovery.registry_pull_failure(pods("ErrImagePull", "429 TooManyRequests", deleting=True)) is None
assert recovery.registry_pull_failure(pods("ErrImagePull", "connection reset")) is None
assert recovery.registry_pull_failure({}) is None

def check_reaped_stat_race(pgid):
    # Schedule a real unrelated task's reap between stat open() and read().
    # No proc contents or exceptions are fabricated.
    disappearing = subprocess.Popen(
        [sys.executable, "-c", "import sys; sys.stdin.read(1)"],
        stdin=subprocess.PIPE, start_new_session=True,
    )
    pidfd = os.pidfd_open(disappearing.pid)
    stat_path = Path("/proc") / str(disappearing.pid) / "stat"
    path_open = Path.open
    raced = False

    def open_then_reap(path, *args, **kwargs):
        nonlocal raced
        stream = path_open(path, *args, **kwargs)
        if path == stat_path:
            try:
                disappearing.stdin.close()
                disappearing.wait(timeout=5)
                raced = True
            except BaseException:
                stream.close()
                raise
        return stream

    try:
        with patch.object(Path, "open", open_then_reap):
            assert not recovery._bootstrap_group_has_executable_members(pgid, time.monotonic() + 3), (
                "a reaped unrelated task prevented proof of the dead owned group")
        assert raced, "the real stat open/reap/read boundary was not exercised"
    finally:
        try:
            signal.pidfd_send_signal(pidfd, signal.SIGKILL)
        except ProcessLookupError:
            pass
        finally:
            os.close(pidfd)
            disappearing.stdin.close()
            disappearing.wait(timeout=5)


child = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(60)"
scratch = tempfile.TemporaryDirectory(prefix="bootstrap-grace-")
cleanup_marker = Path(scratch.name) / "cleaned"
slow_child = f"""import signal,time
from pathlib import Path
def stop(signum, frame):
    time.sleep(1)
    Path({str(cleanup_marker)!r}).write_text("cleaned")
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
print("ready", flush=True)
time.sleep(60)
"""
unrelated_churn = """import os
while True:
    child = os.fork()
    if child == 0:
        os._exit(0)
    os.waitpid(child, 0)
"""
unrelated = subprocess.Popen([sys.executable, "-c", unrelated_churn], start_new_session=True)
try:
    for leader_status, child_script, expect_cleanup in (
        (0, None, False), (7, None, False),
        (None, child, False), (0, child, False), (7, child, False), (7, slow_child, True),
    ):
        leader_script = (
            "import subprocess,sys; "
            f"p=subprocess.Popen({[sys.executable, '-u', '-c', child_script]!r},stdout=subprocess.PIPE,text=True); "
            "assert p.stdout.readline().strip()=='ready'; print(p.pid,flush=True); "
            + ("p.wait()" if leader_status is None else f"sys.exit({leader_status})")
            if child_script is not None else
            f"import os,sys; print(os.getpid(),flush=True); sys.exit({leader_status})"
        )
        owned = subprocess.Popen(
            [sys.executable, "-u", "-c", leader_script],
            stdout=subprocess.PIPE, text=True, start_new_session=True,
        )
        child_fd = leader_fd = None
        try:
            leader_fd = os.pidfd_open(owned.pid)
            assert select.select([owned.stdout], [], [], 5)[0], "owned child did not become ready"
            child_pid = int(owned.stdout.readline())
            child_fd = os.pidfd_open(child_pid)
            if leader_status is not None:
                assert select.select([leader_fd], [], [], 5)[0], "owned leader did not exit first"
                exited = os.waitid(os.P_PID, owned.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG)
                assert exited.si_pid == owned.pid and exited.si_status == leader_status
                assert owned.returncode is None, "leader was reaped before group cleanup"
                if child_script is not None:
                    assert not select.select([child_fd], [], [], 0)[0], "child exited before group cleanup"
            if leader_status == 0 and child_script is None:
                check_reaped_stat_race(owned.pid)
            started = time.monotonic()
            recovery.stop_owned_bootstrap(owned)
            elapsed = time.monotonic() - started
            if child_script == child:
                assert recovery._BOOTSTRAP_STOP_GRACE <= elapsed < recovery._BOOTSTRAP_STOP_GRACE + 15, (
                    f"live TERM-resistant child did not receive the full bounded grace: {leader_status=}, {elapsed=}")
            else:
                assert elapsed < recovery._BOOTSTRAP_STOP_GRACE, (
                    f"empty owned group consumed the remaining cleanup grace: {leader_status=}, {expect_cleanup=}, {elapsed=}")
                if expect_cleanup:
                    assert elapsed >= 1, "graceful child cleanup was cut short"
            assert owned.returncode is not None
            if leader_status is not None:
                assert owned.returncode == leader_status, "cleanup lost the leader's exit status"
            assert select.select([child_fd], [], [], 5)[0], "owned bootstrap child survived group cleanup"
            if expect_cleanup:
                assert cleanup_marker.is_file(), "leader exit cut short the child's SIGTERM cleanup"
            assert unrelated.poll() is None, "bootstrap cleanup stopped an unrelated session"
        finally:
            try:
                recovery.stop_owned_bootstrap(owned)
            finally:
                # Keep fallback cleanup tied to pidfds even if a regression reaps
                # the leader too early or an assertion interrupts the case.
                for fd in (child_fd, leader_fd):
                    if fd is not None:
                        try:
                            signal.pidfd_send_signal(fd, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        finally:
                            os.close(fd)
                owned.wait(timeout=5)
                owned.stdout.close()
finally:
    unrelated.terminate()
    unrelated.wait(timeout=5)
    scratch.cleanup()
print("registry failures are classified without messages; empty groups retire early, live children retain cleanup grace, leader status survives and unrelated sessions remain running")
