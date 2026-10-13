#!/usr/bin/env python3
import copy
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("helper_source", sys.argv[1])
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)
sha = "a" * 40
repo = {"full_name": "dvicory/homelab"}
facts = {
    "actions/workflows/ci.yml": {"id": 340483556, "path": ".github/workflows/ci.yml"},
    "actions/runs/1": {"id": 1, "workflow_id": 340483556, "path": ".github/workflows/ci.yml", "repository": repo, "head_repository": repo, "head_sha": sha, "head_branch": "feature", "event": "pull_request", "actor": {"login": "maintainer"}, "triggering_actor": {"login": "maintainer"}, "pull_requests": [{"number": 2}]},
    "collaborators/maintainer/permission": {"role_name": "maintain", "user": {"login": "maintainer"}},
    "pulls/2": {"state": "open", "head": {"repo": repo, "sha": sha}, "base": {"repo": repo, "ref": "main"}, "user": {"login": "maintainer"}},
    "commits/main": {"sha": sha},
}


def evaluate(data):
    return source.authorize(1, lambda path: copy.deepcopy(data[path]))


assert evaluate(facts) == {"sha": sha, "run": "1"}
admin = copy.deepcopy(facts)
admin["collaborators/maintainer/permission"]["role_name"] = "admin"
assert evaluate(admin)["sha"] == sha
main = copy.deepcopy(admin)
main["actions/runs/1"].update(event="push", head_branch="main", pull_requests=[])
assert evaluate(main)["sha"] == sha
cases = [
    ("wrong workflow ID", "actions/runs/1", "workflow_id", 10),
    ("wrong workflow path", "actions/runs/1", "path", ".github/workflows/unsafe.yml"),
    ("unauthorized actual permission", "collaborators/maintainer/permission", "role_name", "write"),
    ("fork", "actions/runs/1", "head_repository", {"full_name": "attacker/homelab"}),
    ("untrusted source event", "actions/runs/1", "event", "workflow_dispatch"),
    ("closed PR", "pulls/2", "state", "closed"),
    ("stale head", "pulls/2", "head", {"repo": repo, "sha": "b" * 40}),
    ("fork PR", "pulls/2", "head", {"repo": {"full_name": "attacker/homelab"}, "sha": sha}),
    ("multiple PR identities", "actions/runs/1", "pull_requests", [{"number": 2}, {"number": 3}]),
    ("actor injection", "actions/runs/1", "actor", {"login": "$(touch unsafe)"}),
    ("triggering actor injection", "actions/runs/1", "triggering_actor", {"login": "not;authorized"}),
    ("non-immutable SHA", "actions/runs/1", "head_sha", "main"),
]
for label, endpoint, key, value in cases:
    denied = copy.deepcopy(facts)
    denied[endpoint][key] = value
    try:
        evaluate(denied)
    except ValueError:
        pass
    else:
        raise AssertionError(f"unauthorized source accepted: {label}")
print(f"authorization: 3 accepted cases, {len(cases)} refused cases")
