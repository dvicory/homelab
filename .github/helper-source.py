#!/usr/bin/env python3
"""Authorize an exact main-push CI caller, optionally after its required jobs pass."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

REPOSITORY = "dvicory/homelab"
CI_PATH = ".github/workflows/ci.yml"
CI_GATE = "Required CI"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def github(path):
    return json.loads(subprocess.run(["gh", "api", f"repos/{REPOSITORY}/{path}"], check=True, stdout=subprocess.PIPE).stdout)


def authorize(run_id, source_sha, attempt, context, require_ci=True, api=github):
    require(isinstance(run_id, int) and run_id > 0 and isinstance(attempt, int) and attempt > 0, "invalid source run/attempt")
    require(re.fullmatch(r"[0-9a-f]{40}", source_sha), "source SHA must be immutable")
    require(context["GITHUB_REPOSITORY"] == REPOSITORY and context["GITHUB_EVENT_NAME"] == "push" and context["GITHUB_REF"] == "refs/heads/main", "caller is not a trusted repository main push")
    require(context["GITHUB_WORKFLOW_REF"] == f"{REPOSITORY}/{CI_PATH}@refs/heads/main", "caller is not the main CI workflow")
    require(context["GITHUB_SHA"] == source_sha == context["GITHUB_WORKFLOW_SHA"], "source and main-owned tooling differ from caller SHA")
    require(context["GITHUB_RUN_ID"] == str(run_id) and context["GITHUB_RUN_ATTEMPT"] == str(attempt), "source run/attempt differs from caller")
    workflow = api("actions/workflows/ci.yml")
    run = api(f"actions/runs/{run_id}")
    require(workflow["path"] == CI_PATH and run["workflow_id"] == workflow["id"] and run["path"] == CI_PATH, "source is not the known CI workflow")
    require(run["id"] == run_id and run["run_attempt"] == attempt, "source run/attempt changed")
    require(run["repository"]["full_name"] == REPOSITORY and run["head_repository"]["full_name"] == REPOSITORY, "fork or wrong source repository")
    require(run["head_sha"] == source_sha and run["event"] == "push" and run["head_branch"] == "main", "source is not the exact merged-main push")
    if require_ci:
        # The parent workflow is still running its publisher. Its conclusion is
        # not a gate: this completed job already joined every required CI job.
        gates = []
        page = 1
        while True:
            jobs = api(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")["jobs"]
            gates.extend(job for job in jobs if job["name"] == CI_GATE)
            if len(jobs) < 100:
                break
            page += 1
        require(len(gates) == 1 and gates[0]["status"] == "completed" and gates[0]["conclusion"] == "success" and gates[0]["head_sha"] == source_sha, "required CI gate has not passed for this source/attempt")
    return {"sha": source_sha, "run": str(run_id), "attempt": str(attempt)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=int, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--attempt", type=int, required=True)
    parser.add_argument("--caller", action="store_true", help="check source facts in the required CI gate itself; publication always requires its completed success")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        facts = authorize(args.run, args.sha, args.attempt, os.environ, require_ci=not args.caller)
        with Path(args.output).open("a") as stream:
            for key, value in facts.items():
                stream.write(f"{key}={value}\n")
        print(json.dumps(facts))
    except (ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"helper source refused: {error}\n")


if __name__ == "__main__":
    main()
