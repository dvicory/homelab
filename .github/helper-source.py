#!/usr/bin/env python3
"""Authorize a known CI source using GitHub's run, PR and permission facts."""
import argparse
import json
from pathlib import Path
import re
import subprocess

REPOSITORY = "dvicory/homelab"
CI_PATH = ".github/workflows/ci.yml"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def github(path):
    return json.loads(subprocess.run(["gh", "api", f"repos/{REPOSITORY}/{path}"], check=True, stdout=subprocess.PIPE).stdout)


def authorize(run_id, api=github):
    require(isinstance(run_id, int) and run_id > 0, "invalid source run ID")
    workflow = api("actions/workflows/ci.yml")
    run = api(f"actions/runs/{run_id}")
    require(workflow["path"] == CI_PATH and run["workflow_id"] == workflow["id"] and run["path"] == CI_PATH, "source is not the known CI workflow")
    require(run["id"] == run_id and run["repository"]["full_name"] == REPOSITORY and run["head_repository"]["full_name"] == REPOSITORY, "fork or wrong source repository")
    sha = run["head_sha"]
    require(re.fullmatch(r"[0-9a-f]{40}", sha), "source run has no immutable head SHA")

    def maintainer(login):
        require(re.fullmatch(r"[A-Za-z0-9-]{1,39}", login), "source actor is not an approved maintainer")
        permission = api(f"collaborators/{login}/permission")
        require(permission["user"]["login"].lower() == login.lower() and permission["role_name"] in ("admin", "maintain"), "source actor lacks actual maintain/admin repository permission")

    maintainer(run["actor"]["login"])
    maintainer(run["triggering_actor"]["login"])
    if run["event"] == "pull_request":
        require(len(run["pull_requests"]) == 1, "CI source must identify one current pull request")
        number = run["pull_requests"][0]["number"]
        require(isinstance(number, int) and number > 0, "invalid source PR number")
        pr = api(f"pulls/{number}")
        require(pr["state"] == "open" and pr["head"]["repo"]["full_name"] == REPOSITORY and pr["base"]["repo"]["full_name"] == REPOSITORY and pr["base"]["ref"] == "main", "source PR is not an open same-repository main candidate")
        require(pr["head"]["sha"] == sha, "PR head changed since source CI run")
        maintainer(pr["user"]["login"])
    else:
        require(run["event"] == "push" and run["head_branch"] == "main", "unapproved source event/branch")
        require(api("commits/main")["sha"] == sha, "main source changed since CI request")
    return {"sha": sha, "run": str(run_id)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=int, required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        facts = authorize(args.run)
        with Path(args.output).open("a") as stream:
            for key, value in facts.items():
                stream.write(f"{key}={value}\n")
        print(json.dumps(facts))
    except (ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"helper source refused: {error}\n")


if __name__ == "__main__":
    main()
