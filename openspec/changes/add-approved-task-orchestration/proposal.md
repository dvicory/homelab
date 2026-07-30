## Why

Hermes can execute pre-created Kanban graphs, but it lacks an honest policy for deciding when a goal should remain one strong-agent task, when independent work justifies a graph, and how the user approves that graph before execution. The existing automatic triage/decomposition watcher can turn rough intake into runnable children without first presenting task boundaries, cost, dependencies, and external effects to the user.

## What Changes

- Add a gateway-neutral pre-task triage function run by the strongest configured general model in the originating conversation.
- Default every coherent goal to one strong `general` or `code` task; permit a graph only for explicit map, research fan-out, independent review, tournament, pipeline, or latency-hiding cases with separable outputs.
- Render a digest-bound solo/graph proposal in the originating DM, group, or other supported gateway and require an exact approval before creating any runnable tasks.
- Keep the goal conversational before approval; do not create a rough Kanban task or overload operational `triage` status with draft proposals.
- Materialize an approved graph atomically through trusted orchestration, using registered lane names and existing `parents`/`inputs_from` contracts; leaf workers cannot create children.
- Return blocker escalations to operator attention without sending them through task decomposition.
- Define a small initial capability catalogue: `general`, `code`, `review`, and `ops-observe`; keep `local-extract` disabled until a measured narrow workload justifies it.
- Treat operational mutation, Git publication, deployment, rollback, restart, and notification sending as deterministic approval-bound control-plane effects rather than worker-lane powers.
- Measure selected workflows against a strong solo baseline and retain multi-task execution only when it provides material quality, coverage, verification, or wall-clock benefit after coordination cost.

## Capabilities

### New Capabilities

- `approved-task-orchestration`: Pre-task solo/graph recommendation, digest-bound conversational approval, atomic graph materialization, selective decomposition rules, and baseline evaluation.

### Modified Capabilities

- `explicit-worker-lane-routing`: Define the initial semantic lane catalogue, coordinator-versus-leaf topology, and capability-based selection descriptions.
- `multi-task-inputs`: Require approved graph materialization for orchestrator-created fan-out/fan-in and keep leaf workers from expanding graphs.

## Impact

- Hermes orchestrator prompt, tool schema, gateway message/approval integration, Kanban graph creation, automatic decomposition watcher, and task inspection.
- Nix worker-lane catalogue and policy validation.
- Existing immutable input and Project workspace contracts; no new workspace or handoff mechanism.
- Focused evaluation and smoke workflows for solo coding, research fan-out/fan-in, and implementation/review/revision.
