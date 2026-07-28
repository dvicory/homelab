## Context

Hermes currently overloads profiles, assignees, registered external lanes, boards, and Project records. A discovered profile is an implicit worker target, while an external worker is registered through a process-local plugin. Kanban boards are shared across profiles, but upstream Projects are profile-local. Model-facing task creation can also select workspace mechanisms that do not necessarily match the worker process or its terminal and file tools.

This change establishes the routing and authorization vocabulary that broker-backed project workspaces and multi-task artifact inputs will consume. One Hermes instance is one security domain: one Unix account, gateway, dispatcher, broker, state root, lane registry, board catalogue, and trusted Project catalogue. Profiles, lanes, and boards are not tenants.

## Goals / Non-Goals

**Goals:**

- Give every task executor one explicit, instance-wide worker-lane identity.
- Keep the live interactive profile as an orchestrator rather than an implicit worker.
- Allow a lane to determine its runtime, optional backing profile, model, reasoning effort, role/SOUL, tool and skill surface, durable-memory mode, workspace contract, broker policy worklane, approval behavior, resource/runtime limits, and concurrency.
- Make boards coordination namespaces that permit subsets of global lanes and Projects.
- Make logical Project identity and lane access Nix-authoritative and instance-wide.
- Preserve the concise `assignee` task field while defining every accepted assignee as a registered lane, never an implicit profile.
- Freeze one trusted worker specification per task run and make every filesystem-bearing surface consume it.
- Fail before claim or spawn when a board, lane, Project, runtime, or workspace combination is incompatible.
- State honestly that lanes attenuate execution capabilities but do not enforce noninterference between cooperating workers.

**Non-Goals:**

- Multi-tenant isolation between profiles, boards, or lanes.
- Broker materialization of Git Projects; `add-broker-project-workspaces` owns that provider.
- Multi-parent filesystem inputs or general fan-in; `add-multi-task-inputs` owns those data edges.
- Project-controlled workspace-provider allowlists.
- Automatic merge, push, or publication authority.
- Treating SOUL text, tool hiding, or memory namespaces as security boundaries.
- Preserving implicit profile assignments or model-selected workspace paths as compatibility aliases.

## Decisions

### 1. Use six distinct concepts

- **Hermes instance:** the operational and security domain containing the gateway, dispatcher, broker, state, and trusted catalogues.
- **Profile:** an optional Hermes configuration/persona bundle used by a runtime.
- **Worker lane:** a global task-execution contract and capability ceiling.
- **Board:** a shared workflow and coordination namespace.
- **Project:** a stable logical source identity with per-lane access.
- **Task-run binding:** the immutable resolution of one board, task/run, lane, optional Project, runtime, provider, permission, source generation, workspace, and policy identity.

A task belongs to one board, selects one lane through `assignee`, and may select one logical Project. Profiles are never selected directly by ordinary task creation.

**Alternative considered:** make profiles the worker registry. Rejected because profiles are configuration namespaces, are not hard principals, and currently carry profile-local Project state that conflicts with shared boards.

### 2. Keep lane definitions global and let boards attenuate them

The Nix-managed worker-lane registry is global within one Hermes instance. A board declares `allowedLanes`, `allowedProjects`, and an optional `defaultProject`. A board may deny a lane or apply a narrower operational concurrency limit, but it cannot redefine the lane's runtime, provider, tool surface, or security ceiling.

Specialized behavior receives a globally unique lane name such as `security-review` or, when truly tied to one workflow, `homelab-release`. A board-specific name is unnecessary when only Project authorization differs.

**Alternative considered:** define lanes inside boards. Rejected because the same name could acquire different runtime and security meanings, complicating dispatch, audit, Nix validation, and cross-board operations.

### 3. Make Projects Nix-authoritative and provider-agnostic

A managed Project declares a logical source and exactly one `laneAccess` map. An absent lane entry denies direct source access. A value such as `read-only` or `workspace-write` attenuates the lane's maximum filesystem permission.

```nix
projects.homelab = {
  source = {
    type = "git";
    repositoryId = "homelab";
    defaultRef = "main";
  };
  laneAccess = {
    project = "workspace-write";
    review = "read-only";
    codex = "workspace-write";
    codex-plan = "read-only";
  };
};
```

Projects do not declare `allowedProviders`. The lane selects a deterministic provider for project work, and that provider declares the source kinds it supports. A Project that must not reach a host-worktree runtime simply omits that lane from `laneAccess`.

Runtime state owns tasks, claims, events, run bindings, and handoffs. It does not create new managed source identities or broaden `laneAccess` beyond Nix.

**Alternative considered:** a mutable runtime Project catalogue bounded by Nix provider policy. Deferred because it adds source registration, authorization, reconciliation, and recovery machinery before dynamic Projects are needed.

### 4. Profiles are optional runtime presets, not lane identities

A Hermes lane may reference the main managed profile and apply a trusted lane overlay, or may reference a dedicated profile when wholesale configuration or state separation is useful. Merely discovering a profile never registers a lane.

Resolution order is:

1. immutable global/operator floor;
2. referenced profile baseline;
3. trusted lane declaration;
4. bounded task hints, if the lane explicitly permits them;
5. frozen task-run worker specification.

Initially, the interactive orchestrator and ordinary Hermes worker lanes may share one managed base profile. Multiple profiles are optional and do not imply tenancy.

**Alternative considered:** require one profile per lane. Rejected because it duplicates configuration and profile-local state while providing no hard isolation. Dedicated profiles remain available behind explicit lane declarations.

### 5. Lane declarations own complete worker behavior

A lane declaration includes:

- runtime kind and optional profile or plugin;
- fixed model/provider and reasoning effort, or an explicitly bounded set of task overrides;
- role/SOUL overlay beneath immutable operator and security instructions;
- model-visible tools, toolsets, and skills;
- durable-memory mode;
- project mode (`none`, `optional`, or `required`);
- deterministic scratch/project workspace providers and maximum permission;
- supported source kinds and input capability;
- broker policy worklane and approval policy;
- execution timeout, turn limits, resource ceiling, and concurrency;
- completion/output contract.

Model-visible tool filtering and backend authorization are separate requirements. Hiding a tool schema does not grant or revoke broker authority.

Durable memory defaults to `disabled` for task workers. A lane may opt into `lane` or `shared-profile` memory. Task/run transcript state remains isolated regardless of durable-memory mode. A lane namespace controls contamination and organization; it is not a confidentiality boundary from the gateway account.

### 6. Retain `assignee`, but accept registered lanes only

Ordinary task creation retains the concise upstream `assignee` field. Its schema and descriptions enumerate registered lanes and call them worker lanes. Profile names that lack an explicit lane declaration are invalid.

This avoids a broad database and API rename without preserving the old ambiguity. No `lane` alias is added.

Ordinary model-facing task creation must not accept profiles, workspace kinds or paths, providers, permissions, policy worklanes, source URLs, host paths, workspace/lease IDs, or environment keys. Infrastructure acceptance tools may retain separate low-level schemas that are unavailable to normal agents.

### 7. Resolve and persist one immutable worker specification

Before claim or spawn, trusted dispatch resolves:

```text
operator floor
∩ board lane/project policy
∩ lane capability ceiling
∩ Project laneAccess
∩ bounded task intent
```

Provider selection is deterministic from the lane rather than an intersection: the selected provider must support the Project source kind and effective permission. Resolution either returns one complete worker specification or a stable rejection reason. It never silently falls back to another profile, lane, provider, Project, or local workspace.

The persisted binding includes the board-qualified task and run, lane revision, Project/source generation when present, runtime/profile, provider, permission, workspace/lease, policy worklane/digest, agent configuration revision, and memory namespace. Retries create a new run binding; active operations remain fenced to the exact run and workspace generation that created them.

The dispatcher, worker process, terminal, execute-code, file, search, patch, process, and completion surfaces all receive this binding. A worker process CWD and its secure tools must not resolve different logical workspaces.

### 8. Cross-lane collaboration is intentional, not noninterference

Lanes control direct capabilities: source materialization, writable workspace access, tools, broker policy, resource limits, and trusted credential adapters. Workers on one board are cooperating participants. Task bodies, comments, summaries, and later explicit artifact handoffs can carry information across lanes.

Project `laneAccess` governs direct source access, not all derived information. Blocking filesystem handoffs while allowing prose would claim confidentiality the system does not provide. Strong separation requires separate Unix accounts, gateways, brokers, state roots, and an explicit cross-domain export path.

Handoffs must preserve producer task/run, lane, Project/source-generation provenance, but receiving an output never grants direct Project authority.

### 9. Boards are shared coordination, not profile ownership

Boards remain shared under the instance root so an orchestrator and explicitly dispatched workers see one task graph. A worker run is pinned to exactly one board. Profiles do not own boards, lane definitions, or Project identities.

Initially, filesystem inputs remain same-board. Cross-board transfer requires a future explicit import/promotion operation instead of arbitrary task-ID references.

### 10. Keep data edges out of this routing change

This change defines lane input capability and the task-run fields needed by later handoffs but does not implement general input mounting. The dependent input design uses:

- `parents`: ordering and metadata/summary dependency only;
- `inputs_from`: ordering plus explicit immutable producer-output access.

A task does not name the same predecessor twice: `inputs_from` implies readiness gating, and dispatch gates on the union of both sets. This avoids automatically mounting every parent's files while keeping the model contract concise.

## Risks / Trade-offs

- **[Risk] Lane overlays duplicate part of profile resolution.** → Produce one typed resolved worker specification and reuse the existing profile loader as the baseline; do not implement a second free-form config language.
- **[Risk] Process-local external registration differs between dispatchers.** → Run one authoritative dispatcher per board set initially and materialize the Nix lane catalogue in every gateway process before dispatch starts.
- **[Risk] Tool filtering is mistaken for security.** → Pair model schema filtering with broker/backend enforcement derived from the frozen binding.
- **[Risk] Shared gateway state permits cross-lane information flow.** → Document lanes as cooperating roles and require separate instances for mutually distrustful tenants.
- **[Risk] Lane-scoped memory is treated as confidential.** → Default worker durable memory off and state that namespaces are organization, not principal isolation.
- **[Risk] Nix and runtime catalogues drift.** → Persist lane/project revision digests in run bindings and reject removed or incompatible definitions before a new run.
- **[Risk] Global names proliferate for one-off board roles.** → Reuse semantic lanes when behavior matches; create board-prefixed lanes only when model, SOUL, tools, memory, provider, or policy genuinely differs.
- **[Risk] Existing tasks use implicit profiles or workspace fields.** → Make a clean contract break, discard incompatible task/workspace data, and retain no aliases.

## Implementation Order

1. Add typed Nix declarations and validation for global lanes, boards, and managed Projects.
2. Materialize the lane/project catalogue into the gateway and remove implicit profile fallback.
3. Add trusted resolution and durable task-run worker specifications while retaining `assignee` as the lane selector.
4. Route Hermes profile loading, agent configuration, memory, tools, and external plugins through the resolved specification.
5. Bind board, lane, Project, workspace, and policy identity through the existing sandbox-authority control plane.
6. Remove legacy task shapes and update configuration and prompts without compatibility aliases; discard incompatible state.
7. Verify one orchestrator, one Hermes lane, one external lane, board denial, Project denial, conflicting resolution, retry fencing, and cross-surface workspace identity.
8. Finish the narrowed immutable-output and human-delivery boundary in `add-task-workspace-handoff`.
9. Implement broker Project materialization in `add-broker-project-workspaces`.
10. Implement explicit read-only multi-task inputs in `add-multi-task-inputs`.

## Open Questions

None for the initial architecture. Dynamic Project registration, cross-board imports, mandatory information-flow controls, and distributed dispatchers require separate proposals if needed.
