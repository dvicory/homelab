"""Run directly with the recovery driver path; no cluster or production state."""
import importlib.util
import os
import select
import signal
import subprocess
import sys

spec = importlib.util.spec_from_file_location("recovery", sys.argv[1])
recovery = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = recovery
spec.loader.exec_module(recovery)


def pods(reason, message, namespace="argocd", deleting=False):
    return {"items": [{"metadata": {"namespace": namespace, "deletionTimestamp": "retiring" if deleting else None},
                       "status": {"containerStatuses": [{"state": {"waiting": {"reason": reason, "message": message}}}]}}]}


secret = "synthetic-sensitive-value"
assert recovery.registry_pull_failure(pods("ErrImagePull", "429 TooManyRequests " + secret)) == "rate-limited"
assert recovery.registry_pull_failure(pods("ImagePullBackOff", "unauthorized " + secret)) == "unauthorized"
assert recovery.registry_pull_failure(pods("ErrImagePull", "manifest unknown " + secret)) == "manifest-not-found"
assert recovery.registry_pull_failure(pods("ErrImagePull", "x509: " + secret)) == "certificate"
assert recovery.registry_pull_failure(pods("CrashLoopBackOff", "429 TooManyRequests")) is None
assert recovery.registry_pull_failure(pods("ErrImagePull", "429 TooManyRequests", namespace="other")) is None
assert recovery.registry_pull_failure(pods("ErrImagePull", "429 TooManyRequests", deleting=True)) is None
assert recovery.registry_pull_failure(pods("ErrImagePull", secret)) is None
assert recovery.registry_pull_failure({}) is None

child = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(60)"
unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
try:
    for leader_status in (None, 0, 7):
        owned = subprocess.Popen(
            [sys.executable, "-u", "-c", "import subprocess,sys; "
             f"p=subprocess.Popen({[sys.executable, '-u', '-c', child]!r},stdout=subprocess.PIPE,text=True); "
             "assert p.stdout.readline().strip()=='ready'; print(p.pid,flush=True); "
             + ("p.wait()" if leader_status is None else f"sys.exit({leader_status})")],
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
                assert not select.select([child_fd], [], [], 0)[0], "child exited before group cleanup"
            recovery.stop_owned_bootstrap(owned)
            assert owned.returncode is not None
            if leader_status is not None:
                assert owned.returncode == leader_status, "cleanup lost the leader's exit status"
            assert select.select([child_fd], [], [], 5)[0], "owned bootstrap child survived group cleanup"
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
print("registry failures are classified without messages; application/unrelated/retiring state is not an upstream failure; running and exited-but-unreaped leaders lose owned children without touching unrelated sessions")
