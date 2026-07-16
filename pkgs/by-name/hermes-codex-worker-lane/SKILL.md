---
name: codex
description: Route explicitly delegated software engineering, code review, debugging, and architecture tasks through operator-managed Kanban worker lanes. Use when the user asks Hermes to create or delegate a new software task, including requests to have Codex plan, review, investigate, or change code in an existing project.
version: 1.0.0
author: Daniel Vicory
license: MIT
metadata:
  hermes:
    tags: [Coding-Agent, Codex, Architecture, Code-Review, Refactoring]
---

# Codex Kanban worker lanes

Codex is available through operator-managed external Kanban worker lanes. Lane
names are assignees, not Hermes profiles. Do not create, clone, select, or look
up a Hermes profile for a lane.

Use this skill only when the user explicitly asks to delegate a concrete
software task. A question about code, or a request for Hermes' own opinion, is
not permission to start a worker.

## Available lanes

@lane-guide@

Choose the single lane whose operator-defined use best matches the requested
work. If multiple lanes plausibly match and their policy difference matters,
ask the user rather than silently choosing broader authority.

The lane policy, model, reasoning effort, sandbox, network access, concurrency,
and approval behavior are operator-owned. Do not claim broader authority or try
to change those settings from a task.

## Create the task

1. Identify the existing Hermes project that owns the requested repository. Do
   not assume `homelab`; Codex can work in any declared project. If the intended
   project is ambiguous or absent, ask the user instead of inventing one.
2. Write a self-contained task body with the objective, motivation, relevant
   context, constraints, acceptance criteria, and expected validation. Preserve
   any explicit limits the user gave Hermes.
3. For new planning or implementation work, call `kanban_create` with the exact
   lane assignee, the existing project slug, and `workspace_kind="worktree"`.
   A project-backed worktree isolates the task from the canonical checkout and
   gives it a deterministic branch.
4. For a read-only review of an existing Kanban task, first inspect that task
   with `kanban_show` and follow the generic Kanban parent-link guidance. If its
   preserved worktree exists, use that absolute path with
   `workspace_kind="dir"` so the reviewer sees the exact checkout. Otherwise
   use a project worktree and tell the reviewer the exact source branch or
   commit to inspect with read-only Git commands. Hermes creates and preserves
   task worktrees, but a new task branches from the project's current `HEAD`;
   Kanban parent links do not implicitly select a Git base revision.
5. Report the returned task id and lane. Never invent an id or say Codex started
   unless `kanban_create` succeeded.

Example shapes (illustrative, not literal tool calls to repeat blindly):

```text
kanban_create(
  title="Design the cache invalidation boundary",
  assignee="<selected lane name>",
  project="existing-project",
  workspace_kind="worktree",
  body="Why this is needed, current constraints, questions to answer, and the expected design deliverable."
)

kanban_create(
  title="Review the cache invalidation implementation",
  assignee="<selected read-only lane name>",
  parents=["<source task id>"],
  workspace_kind="dir",
  workspace_path="<absolute preserved source-task worktree>",
  body="Review scope, acceptance criteria, expected findings, and the exact source revision. Do not modify files."
)

kanban_create(
  title="Implement bounded cache invalidation",
  assignee="<selected lane name>",
  project="existing-project",
  workspace_kind="worktree",
  body="Why this is needed, scoped implementation requirements, acceptance criteria, and checks to run."
)
```

## Boundaries

- Never invoke the Codex CLI through the terminal, background processes, or a
  shell wrapper. The worker lane owns process launch and policy enforcement.
- Never use a shared directory for modifying work. Use the declared project and
  a task worktree.
- Do not push, merge, deploy, expose credentials, or weaken sandboxing unless a
  separately established operator workflow explicitly authorizes it.
- A worker that changes files normally blocks for review. Treat that as the
  expected approval boundary, not as a failure to bypass.
