## Why

The immutable-output handoff freezes each completed task's `/workspace/output` for trusted local human delivery, but it does not expose producer files to another worker. After broker Project workspaces establish separate work/input/output planes, Kanban needs explicit immutable data edges for pre-created fan-in/fan-out without exposing broker mechanisms.

## What Changes

- Add model-facing `inputs_from` task relationships distinct from `parents`: `parents` gates on status and supplies summaries/metadata, while `inputs_from` also gates readiness and mounts frozen producer output.
- Make `inputs_from` imply dependency gating so a producer is never named in both fields merely to receive files; readiness uses the union of both edge sets.
- Permit explicit same-board fan-out and fan-in from multiple completed producer tasks without exposing handoff, generation, lease, provider, or mount identities.
- Mount each selected frozen producer output read-only at `/workspace/inputs/<stable-task-name>/`; never merge inputs with one another, `/workspace/work`, or `/workspace/output`.
- Preserve producer task/run, lane, Project/source-generation, and handoff provenance across cross-lane consumption while granting no direct Project authority to the recipient.
- Enforce lane input count/byte/entry/path limits, exact producer readiness, immutable handoff identity, same-board scope, retention references, replay, revocation, and cleanup before destination execution.

## Capabilities

### New Capabilities

- `multi-task-inputs`: Explicit immutable task data edges, same-board fan-in/fan-out, namespaced read-only mounts, provenance, limits, retention, and fail-closed resolution.

### Modified Capabilities

- `task-workspace-handoffs`: Ready frozen task outputs become reusable immutable sources for explicit `inputs_from` edges while their human-delivery manifest remains a separate selected subset.
- `kanban-sandbox-workspace`: Task readiness and workspace activation resolve zero or more immutable input bindings into the canonical inputs plane.

## Impact

- Kanban task schema, graph validation, readiness computation, dispatcher, task-run bindings, model tool descriptions, summaries, and UI/CLI rendering.
- Broker handoff reference model, input preparation, VFS read-only mounts, lifecycle recovery, retention/reference accounting, and cleanup.
- Hermes workspace guidance and orchestration prompts.
- Depends on `add-explicit-worker-lanes`, the narrowed `add-task-workspace-handoff`, and `add-broker-project-workspaces`.
