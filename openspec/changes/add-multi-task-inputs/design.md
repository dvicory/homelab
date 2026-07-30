## Context

The narrowed workspace handoff freezes each completed task's complete `/workspace/output` and authorizes only selected files for human delivery. It deliberately provides no worker-to-worker import or input mount. `add-explicit-worker-lanes` supplies trusted lane/input ceilings and frozen task-run identity; `add-broker-project-workspaces` supplies separate `/workspace/work`, `/workspace/inputs`, and `/workspace/output` planes. This change adds explicit immutable data edges on top of those completed contracts.

## Goals / Non-Goals

**Goals:**

- Represent scheduling-only relationships separately from filesystem data dependencies.
- Allow pre-created same-board fan-in and fan-out across registered lanes.
- Mount each producer's exact frozen output read-only and namespaced.
- Preserve provenance without granting the receiving lane direct Project access.
- Keep broker identities, providers, mounts, leases, and paths out of model control.
- Bind inputs reproducibly to the destination task run with durable replay and retention.

**Non-Goals:**

- Automatic merge of files, repositories, patches, or Project generations.
- Cross-board or cross-instance inputs.
- Mandatory information-flow isolation between cooperating lanes.
- Selecting arbitrary files from producer workspaces or live VMs.
- Making every scheduling parent a filesystem input.
- Model-selected handoff IDs, mount paths, source generations, or storage providers.
- Content-addressed deduplication as a prerequisite.

## Decisions

### 1. Keep two edge types, but never require duplicate declarations

The model-facing task API retains:

- `parents`: ordering plus existing summary/metadata relationships, with no file mount;
- `inputs_from`: ordering plus immutable producer-output access.

`inputs_from` implies readiness gating. Dispatch computes dependencies from the union of `parents` and `inputs_from`, so a producer does not need to appear in both fields. Duplicate membership is rejected or normalized to the stronger input edge; the model is never instructed to repeat it.

Examples:

```python
kanban_create(parents=["tests"], inputs_from=[])
```

waits for tests but mounts no files, while:

```python
kanban_create(inputs_from=["research-a", "research-b"])
```

waits for both and mounts both frozen outputs.

**Alternative considered:** automatically mount every parent's output. Rejected because many dependency edges need only status or prose, automatic mounting expands data exposure and retention, and large fan-in would consume resources unexpectedly.

**Alternative considered:** rename the complete API to `depends_on` and `inputs`. Rejected because `parents` is already pervasive and `inputs_from` states the source relation clearly with a smaller patch.

### 2. Store explicit task input edges and resolve opaque sources later

Kanban stores a destination task ID and producer task ID, both board-qualified. The model does not store a handoff ID, producer run, workspace, lease, provider, generation, or mount path.

Before the destination first becomes runnable, trusted resolution verifies every producer is `done` with one ready frozen handoff and persists an input-binding set containing the exact producer task/run, lane, optional Project/source generation, handoff, output manifest, and destination task generation. Once bound, later producer retries or catalogue changes do not silently replace the destination's inputs.

A destination retry reuses its persisted immutable input set unless a trusted operation explicitly resets the destination before a new run. Any input-edge mutation increments the destination's task/input generation and is forbidden while a run is active.

### 3. Use stable collision-free mount names

Each producer output appears at:

```text
/workspace/inputs/<producer-task-id>/
```

The normalized board-local task ID is the canonical name because titles and user labels can collide or change. Task context and Kanban inspection expose the mapping from task ID to title, producer lane, Project provenance, and guest path. Optional human aliases are deferred until they have a collision and mutation contract.

Inputs are directories containing the producer's complete frozen `/workspace/output` tree. Human-delivery `artifacts` remain a selected subset and do not control worker-to-worker input visibility.

### 4. Inputs are immutable, read-only, and never merged

The broker mounts or presents each ready handoff as a separate read-only VFS subtree under `/workspace/inputs`. It does not copy inputs into `/workspace/work` or `/workspace/output`, overlay parents, resolve filename collisions, or choose merge precedence.

A worker may deliberately copy data from an input into its private work or output plane when its lane permits writes. Such copies become destination-owned mutable data; they do not alter the source handoff.

Backend implementation may share immutable storage across fan-out recipients. The externally visible contract is identical whether backed by direct read-only mounts, snapshots, reflinks, or copies.

### 5. Same-board cross-lane collaboration is allowed

A producer and destination may use different registered lanes. Input resolution validates the destination board policy and lane input capability, but receiving a handoff does not add the producer Project to the destination's direct Project authority.

Every binding preserves producer task/run, lane, Project/source-generation when present, handoff, and output-manifest provenance. This is audit data, not an information-flow label. Task bodies, summaries, comments, and explicit outputs already permit cooperating lanes to distill information.

Initially, producer and destination must belong to the same board and instance. Cross-board or cross-instance transfer needs an explicit trusted export/import proposal.

### 6. Lane declarations bound input resources

A lane declares whether it supports inputs and its hard maximum input count, aggregate logical bytes, entries, path bytes, and per-input limits. Broker policy may further attenuate these values. Resolution sums immutable producer manifests before destination activation and fails closed when a limit is exceeded.

The ordinary model selects only producer task IDs. It cannot select mount names, handoffs, storage mechanisms, bypass limits, or request writable inputs.

Resource accounting must distinguish logical per-destination exposure from physical deduplicated storage. Deduplication does not remove logical quota or retention obligations.

### 7. Readiness fails closed without empty substitutes

A task cannot run while any `parents` or `inputs_from` producer is incomplete according to Kanban readiness. For an input edge, `done` alone is insufficient: the exact producer completion must have one ready handoff, including an intentionally empty frozen output.

Blocked, failed, reclaimed, missing, ambiguous, expired, quarantined, or publication-failed producer output keeps the destination non-runnable with a stable reason. The dispatcher does not omit the input, mount a live workspace, create an empty substitute, redispatch the producer silently, or fall back to summaries.

An intentionally empty ready handoff is a valid input and mounts an empty read-only directory.

### 8. Bind preparation and activation transactionally

Trusted input resolution creates a deterministic preparation identity from the destination task/input generation and the complete ordered producer binding set. The broker journals preparation, validates all handoffs and limits, acquires retention references, and returns opaque prepared input identities to trusted workspace activation.

Destination execution begins only when its work/output workspace lease and all read-only input bindings belong to one frozen task-run authority record. Identical replay returns the same result. Any changed producer, handoff, manifest, limit, destination generation, lane, board, or policy fact fails as a conflict.

No input mount is exposed through the execution listener before authority registration completes.

### 9. Gate handoff reclaim on explicit archive

Each destination input binding holds a durable reference to the producer handoff. Producer workspace cleanup is independent, but frozen output remains available to live and future declared consumers until the producer is explicitly archived.

Kanban lifecycle makes `done` and `archived` terminal. Retry occurs only through `blocked → unblock → ready` before completion, so a destination retry can reuse its exact input pin while a completed producer cannot silently create a newer completion. Any future trusted re-completion capability must preserve existing pins and require an explicit trusted act to select newer output.

Time-based retention is unsuitable for declared inputs. TTL or sliding-window deletion would make a destination's validity clock-dependent and could create an unrecoverable dangling edge after its terminal producer can no longer rerun. Graph-wide completion is also insufficient because new consumers may be added later.

The broker therefore deletes ready handoff bytes only after the producer is explicitly archived and no acquired input references remain. Archiving refuses non-terminal consumers, and task creation rejects `inputs_from` edges to archived producers; both guards are Kanban-local and require no broker query.

Destination finalization releases the completed run's references. Archiving a destination idempotently releases every retained preparation for that task. Failed or blocked destinations keep references so retry receives bit-identical inputs. Mark-reclaimable, release, and finalization each attempt eligible deletion synchronously; there are no timers or sweeps.

The archive path pushes release and mark-reclaimable operations using durable handoff identities. Workspace-service initialization reconciles missed pushes from archived Kanban records, so broker downtime does not make archive authority depend on transient delivery. `expired` remains a stable defense-in-depth reason for genuine data loss or manual corruption, not a routine retention outcome.

Fan-out shares one immutable producer handoff across references; it does not create writable clones per child.

### 10. Keep output and Project semantics orthogonal

A destination always receives its own work plane and output plane in addition to zero or more inputs. For a Project task:

```text
/workspace/work/                     private Project source generation
/workspace/inputs/<producer-id>/     immutable task output
/workspace/output/                   destination output
```

For scratch work, `/workspace/work` is private scratch with the same input/output shape. Project lane access governs only direct Project source authority. Inputs may carry Project-derived information but do not mount producer Project workspaces or confer repository credentials.

Code-result fan-in does not silently merge repository changes. Producers must place patches, reports, bundles, or other explicit data in output, and a synthesis task applies or reconciles them deliberately in its own work plane.

## Risks / Trade-offs

- **[Risk] `parents` and `inputs_from` are still two concepts.** → Make `inputs_from` imply dependency gating and explain the single distinction: parent is ordering; input also supplies files.
- **[Risk] Same-board lanes can transfer Project-derived information.** → State that lanes are least-privilege execution roles, not noninterference tenants; use separate instances for mutually distrustful workloads.
- **[Risk] A future trusted re-completion feature changes producer output.** → Preserve every existing destination's exact producer task/run/handoff pin and require an explicit trusted act to select a newer completion.
- **[Risk] Fan-out pins storage until explicit producer retirement.** → Use archive-gated reclaim, durable reference accounting, Kanban-local archive guards, quotas, and startup reconciliation.
- **[Risk] Many mounts increase VFS and startup cost.** → Enforce lane count/byte/entry ceilings and measure activation before raising defaults.
- **[Risk] Task IDs are unfriendly paths.** → Surface title/path mappings in worker context; defer mutable aliases rather than compromise collision-free identity.
- **[Risk] Worker guidance conflates human artifact selection with filesystem inputs.** → State that `artifacts` selects files for humans while `inputs_from` selects complete frozen producer outputs for workers.

## Implementation Order

1. Complete and verify `add-explicit-worker-lanes`, the narrowed `add-task-workspace-handoff`, and `add-broker-project-workspaces`.
2. Add durable `inputs_from` task edges, destination input generations, exact producer bindings, and retention references.
3. Update task creation, inspection, readiness, graph validation, and dynamic schema descriptions; retain `parents` for ordering-only edges.
4. Implement broker input preparation, replay/conflict detection, limit validation, read-only VFS mounts, and crash reconciliation.
5. Bind prepared inputs atomically with the destination task-run workspace and sandbox authority.
6. Update Hermes worker context and guidance to list canonical input paths and provenance.
7. Verify zero, one, and multiple inputs; fan-out; fan-in; cross-lane use; empty output; destination retry; edge mutation; limits; stale runs; outage replay; archive-gated reclaim; and cleanup.
8. Smoke-test a pre-created research fan-out/fan-in workflow and a Project implementation/review/revision workflow.


## Open Questions

Cross-board imports, optional human input aliases, selected sub-output contracts, and content-addressed deduplication are deferred. They are not required for same-board fan-in/fan-out.

