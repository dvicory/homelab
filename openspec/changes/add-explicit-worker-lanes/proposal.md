## Why

Kanban currently treats every discoverable Hermes profile as an implicit worker fallback while registered external lanes use a separate process-local contract. Board selection, profile configuration, project records, workspace mechanisms, and assignee arguments can therefore disagree about what a worker may access and where its tools operate. We need one explicit routing contract before adding broker-backed project work or general artifact fan-in.

## What Changes

- **BREAKING** Replace implicit profile-as-assignee fallback with an explicit instance-wide worker-lane registry. A Hermes profile is spawnable only when an operator-declared lane references it.
- Keep the interactive Hermes profile as the live orchestrator rather than an automatically assignable worker lane.
- Let each lane declare its runtime, optional Hermes profile, model, reasoning effort, role/SOUL, tool and skill surface, memory scope, workspace contract, policy worklane, approvals, resource/runtime limits, and concurrency.
- Treat boards as shared cross-profile coordination namespaces that permit subsets of globally defined lanes and logical projects; boards and profiles are not tenancy boundaries.
- Move logical project identity and security-relevant project policy into an instance-wide trusted catalogue. A project declares source identity and one `laneAccess` map; it does not select or allowlist workspace providers.
- Narrow ordinary model-facing task creation to a lane, optional logical project, dependency relationships, and bounded task intent. Remove model control over profiles, workspace kinds or paths, providers, permissions, policy worklanes, leases, and host paths.
- Resolve and persist one immutable task-run worker specification before spawn. Every filesystem-bearing surface must consume that same board, task/run, lane, project, provider, permission, source-generation, workspace, and policy binding.
- State the security boundary explicitly: lanes attenuate direct execution capabilities but are cooperating roles within one Hermes instance, not mandatory information-flow compartments or tenants.

## Capabilities

### New Capabilities

- `explicit-worker-lane-routing`: Instance-wide lane declaration, board and project authorization, trusted task resolution, profile/runtime selection, agent configuration, and fail-closed dispatch.

### Modified Capabilities

- `task-sandbox-authority`: Task/run authority is extended to bind the resolved lane, board, project, workspace contract, and policy identity used by every worker surface.

## Impact

- Patched Hermes worker-lane registry, Kanban schemas, dispatcher, profile launch, agent configuration, memory/tool filtering, and task-run persistence.
- NixOS/Home Manager Hermes declarations for lanes, boards, projects, policy worklanes, and validation.
- Gondolin workspace-service authority binding and broker policy selection.
- Existing implicit `default` profile assignments and model-facing `workspace_kind`/`workspace_path` calls are removed in a clean cutover; incompatible task and workspace state may be discarded.
- The narrowed immutable-output handoff, broker Project materialization, and multiple artifact inputs remain separate dependent changes.
