from __future__ import annotations

import os
from pathlib import Path
import shutil

from hermes_cli import worker_catalogue as worker_catalogue
from hermes_cli.worker_catalogue import load_worker_catalogue
from hermes_cli.worker_catalogue import resolve_worker_specification
import model_tools
from tools import kanban_tools


source = Path(os.environ["HERMES_QA_CONFIG"])
home = Path(os.environ["HERMES_HOME"])
home.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source, home / "config.yaml")

catalogue = load_worker_catalogue(required=True)
if set(catalogue["boards"]) != {"homelab"}:
    raise RuntimeError(f"deployed QA boards are incorrect: {sorted(catalogue['boards'])}")
if set(catalogue["lanes"]) != {"research", "codex-plan", "codex"}:
    raise RuntimeError(f"deployed QA lanes are incorrect: {sorted(catalogue['lanes'])}")

research = resolve_worker_specification("research", board="homelab")
worker_catalogue.load_current_worker_specification = lambda: research
allowed = model_tools._worker_allowed_tools()
required_workspace_tools = {"terminal", "process", "read_file", "write_file"}
if allowed is None or not required_workspace_tools <= allowed:
    raise RuntimeError(
        "deployed research lane lacks workspace tools: "
        f"{sorted(required_workspace_tools - (allowed or set()))}"
    )

os.environ["HERMES_KANBAN_BOARD"] = "homelab"
overrides = kanban_tools._kanban_create_schema_overrides()
assignees = overrides["parameters"]["properties"]["assignee"].get("enum")
if assignees != ["codex", "codex-plan", "research"]:
    raise RuntimeError(f"model-facing QA assignees are incorrect: {assignees!r}")
