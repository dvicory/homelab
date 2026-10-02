"""Fail closed on named safety scenarios, not incidental operation counts."""

# Independent of fixture discovery and supplied settings: missing a family or
# selecting a smaller fixture cannot redefine full acceptance.
REQUIRED_SCENARIOS = [
    "gateway-cel-admission",
    "argo-01-child-gating-recovery",
    "argo-02-retained-hook-sequencing",
    "argo-03-workload-self-heal",
    "argo-04-git-omission",
    "argo-05-direct-retirement",
    "argo-06-root-child-retirement",
    "runtime-secret-initial-exact-ack",
    "runtime-secret-missing-desired-inventory",
    "runtime-secret-stale-desired-inventory",
    "runtime-secret-malformed-desired-inventory",
    "runtime-secret-malformed-owned-inventory",
    "runtime-secret-duplicate-owned-inventory",
    "runtime-secret-failed-uid-recording-keeps-ack",
    "runtime-secret-ssa-uid",
    "runtime-secret-empty-generation-relinquishes-only-owned-fields",
    "runtime-secret-matching-uid-shared-owner-tls-retirement",
    "runtime-secret-matching-uid-sole-owner-tls-retirement",
    "runtime-secret-projected-mode-zero-unreadable",
    "runtime-secret-fsgroup-readable",
    "gateway-current-generation-status",
    "gateway-direct-source-spoofing",
    "gateway-trusted-cni-source-boundary",
    "gateway-referencegrant-deny-restore",
    "gateway-backend-name-deny-restore",
    "gateway-backend-ca-deny-restore",
    "gateway-real-webauthn-authorization",
    "gateway-access-error-log-privacy",
]


def check_report(raw, required):
    if not required or len(required) != len(set(required)):
        raise ValueError("required-scenario-inventory")
    tests = raw.get("tests") or []
    names = [test.get("name") for test in tests]
    if len(names) != len(required) or set(names) != set(required):
        raise ValueError("scenario-coverage")
    for test in tests:
        steps = test.get("steps") or []
        if not steps:
            raise ValueError("step-coverage")
        if test.get("status") != "passed" or any(
            step.get("status") != "passed"
            or not step.get("operations")
            or any(op.get("status") != "passed" or op.get("failure") for op in step["operations"])
            for step in steps
        ):
            raise ValueError("scenario-failure-or-skip")


def self_check():
    import copy

    required = ["safety-one", "safety-two"]
    good = {"tests": [{"name": name, "status": "passed", "steps": [{"status": "passed", "operations": [{"status": "passed"}]}]} for name in required]}
    check_report(good, required)
    probes = [None, {}, {"tests": []}, {"tests": good["tests"][:1]}, {"tests": good["tests"] * 2}]
    for path, value in [("test", "skipped"), ("step", "failed"), ("operation", "skipped"), ("operations", []), ("failure", "failure"), ("steps", [])]:
        bad = copy.deepcopy(good)
        test = bad["tests"][0]
        step = test["steps"][0]
        if path == "test":
            test["status"] = value
        elif path == "step":
            step["status"] = value
        elif path == "operation":
            step["operations"][0]["status"] = value
        elif path == "failure":
            step["operations"][0]["failure"] = value
        elif path == "steps":
            test["steps"] = value
        else:
            step["operations"] = value
        probes.append(bad)
    for bad in probes:
        try:
            check_report(bad or {}, required)
        except ValueError:
            continue
        raise AssertionError("incomplete report accepted")


if __name__ == "__main__":
    self_check()
