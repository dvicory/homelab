#!/usr/bin/env python3
import copy
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("helper_source", sys.argv[1])
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)
sha = "a" * 40
repo = {"full_name": "dvicory/homelab"}
context = {
    "GITHUB_REPOSITORY": repo["full_name"],
    "GITHUB_EVENT_NAME": "push",
    "GITHUB_REF": "refs/heads/main",
    "GITHUB_WORKFLOW_REF": "dvicory/homelab/.github/workflows/ci.yml@refs/heads/main",
    "GITHUB_WORKFLOW_SHA": sha,
    "GITHUB_SHA": sha,
    "GITHUB_RUN_ID": "1",
    "GITHUB_RUN_ATTEMPT": "2",
}
jobs_path = "actions/runs/1/attempts/2/jobs?per_page=100&page=1"
facts = {
    "actions/workflows/ci.yml": {"id": 340483556, "path": ".github/workflows/ci.yml"},
    "actions/runs/1": {"id": 1, "run_attempt": 2, "workflow_id": 340483556, "path": ".github/workflows/ci.yml", "repository": repo, "head_repository": repo, "head_sha": sha, "head_branch": "main", "event": "push", "status": "in_progress", "conclusion": None},
    jobs_path: {"jobs": [{"name": "Required CI", "status": "completed", "conclusion": "success", "head_sha": sha}]},
}


def evaluate(data=facts, caller=context, require_ci=True, **kwargs):
    arguments = dict(run_id=1, source_sha=sha, attempt=2, context=caller, require_ci=require_ci, api=lambda path: copy.deepcopy(data[path]))
    arguments.update(kwargs)
    return source.authorize(**arguments)


def refused(label, **kwargs):
    try:
        evaluate(**kwargs)
    except ValueError:
        pass
    else:
        raise AssertionError(f"unauthorized source accepted: {label}")


# Publication joins completed required jobs, not the still-running parent run.
assert evaluate() == {"sha": sha, "run": "1", "attempt": "2"}
no_gate = copy.deepcopy(facts)
no_gate[jobs_path]["jobs"] = []
assert evaluate(no_gate, require_ci=False)["sha"] == sha  # caller gate itself
refused("publisher without completed required gate", data=no_gate)
for key, value in (
    ("GITHUB_REPOSITORY", "attacker/homelab"),
    ("GITHUB_EVENT_NAME", "pull_request"),
    ("GITHUB_EVENT_NAME", "workflow_dispatch"),
    ("GITHUB_REF", "refs/heads/feature"),
    ("GITHUB_WORKFLOW_REF", "dvicory/homelab/.github/workflows/other.yml@refs/heads/main"),
    ("GITHUB_WORKFLOW_SHA", "b" * 40),
    ("GITHUB_SHA", "b" * 40),
    ("GITHUB_RUN_ID", "9"),
    ("GITHUB_RUN_ATTEMPT", "1"),
):
    denied = dict(context, **{key: value})
    refused(key, caller=denied)
    refused(f"caller {key}", caller=denied, require_ci=False)
for key, value in (
    ("workflow_id", 10),
    ("path", ".github/workflows/other.yml"),
    ("id", 9),
    ("run_attempt", 1),
    ("repository", {"full_name": "attacker/homelab"}),
    ("head_repository", {"full_name": "attacker/homelab"}),
    ("head_sha", "b" * 40),
    ("head_branch", "feature"),
    ("event", "workflow_dispatch"),
    ("event", "pull_request"),
):
    denied = copy.deepcopy(facts)
    denied["actions/runs/1"][key] = value
    refused(key, data=denied)
for key, value in (
    ("name", "successful build only"),
    ("status", "in_progress"),
    ("conclusion", "failure"),
    ("conclusion", "skipped"),
    ("conclusion", "cancelled"),
    ("head_sha", "b" * 40),
):
    denied = copy.deepcopy(facts)
    denied[jobs_path]["jobs"][0][key] = value
    refused(key, data=denied)
duplicate = copy.deepcopy(facts)
duplicate[jobs_path]["jobs"] *= 2
refused("ambiguous CI receipt", data=duplicate)
paginated = copy.deepcopy(facts)
paginated[jobs_path]["jobs"] = [{"name": "other"}] * 100
paginated["actions/runs/1/attempts/2/jobs?per_page=100&page=2"] = facts[jobs_path]
assert evaluate(paginated)["sha"] == sha
for arguments in ({"run_id": 0}, {"attempt": 0}, {"source_sha": "main"}):
    refused("invalid immutable source identity", **arguments)
print("main CI source and completed required-job receipt authorization passed")
