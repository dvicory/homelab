## Context

The current Project-linked Kanban path and Gondolin secure-tool path disagree. Upstream Project dispatch creates a gateway-owned linked host worktree and starts the worker process there, while terminal, execute-code, file, search, and patch operations use a separate broker workspace mounted at `/workspace`. Mounting the host worktree into Gondolin would expose shared Git metadata, host paths, gateway ownership, and cross-task coupling.

`add-explicit-worker-lanes` makes Project identity, lane permission, and provider selection trusted inputs to one task-run binding. This change supplies the missing `broker-project` provider and a workspace shape that also supports the later multi-input change.

## Goals / Non-Goals

**Goals:**

- Materialize a complete task-private Project source generation under broker ownership.
- Give the worker process and all secure tools one canonical workspace.
- Separate mutable work, immutable inputs, and publishable output structurally.
- Support read-only and workspace-write Project lanes without granting source publication.
- Keep private-source credentials and the gateway checkout outside the guest.
- Persist generation, lease, lifecycle, retention, and result provenance for recovery and audit.
- Make a clean layout break and discard legacy workspaces and queued tasks.

**Non-Goals:**

- Mounting or cloning from the gateway's linked worktree or canonical checkout.
- General multi-task inputs; `/workspace/inputs` is empty until `add-multi-task-inputs` supplies mounts.
- Automatic merge, push, or mutation of a canonical Project generation.
- Arbitrary model-supplied repository URLs, revisions, host paths, mount definitions, or credentials.
- Content-addressed or Merkle storage as a prerequisite.
- Cross-Project merge semantics or distributed source-provider operation.

## Decisions

### 1. Adopt a canonical three-plane workspace

Every newly activated broker task workspace has:

```text
/workspace/
├── work/       mutable Project checkout or scratch work plane
├── inputs/     read-only namespaced immutable inputs
└── output/     task-owned mutable publication candidates
```

The worker CWD is `/workspace/work`. Completion continues to freeze and validate only `/workspace/output`. `/workspace/inputs` is broker-managed and cannot be written by the worker. A read-only Project lane receives a read-only work plane while retaining a bounded writable output plane for its report.

External Codex follows the same layout but does not receive Kanban lifecycle authority. Codex runs with CWD `/workspace/work` and returns an explicit `artifacts` array in its structured result. Every entry is a normalized workspace-root path below `output/`, even though ordinary relative filesystem operations begin in `/workspace/work`; CWD-relative `../output/...` forms are rejected rather than normalized across planes. The trusted Codex wrapper validates the schema and passes the selected paths to Kanban completion. Git changed-path discovery remains Project-result metadata and never selects human artifacts. Kanban captures the complete output tree for later task inputs while native human delivery exposes only the selected subset.

**Alternative considered:** let Codex call `kanban_complete` directly. Rejected because the wrapper owns heartbeats and the single terminal transition; giving the child lifecycle authority creates competing completion, retry, and fencing paths.

**Alternative considered:** automatically select every file in `/workspace/output` for human delivery. Rejected because frozen worker-to-worker output and intentionally selected human attachments have different disclosure and resource semantics.

Existing workspaces and queued tasks using `/workspace` as their work root may be discarded; no symlink, path alias, or dual-layout resolver is added.

**Alternative considered:** keep the repository at `/workspace` and add orchestration directories below it. Rejected because `inputs/` and `output/` would contaminate repository status and tools would need special path exclusions.

### 2. Materialize provider-neutral source generations

The Project catalogue names a logical `SourceSpec`; it does not define Project as synonymous with a Git repository. A trusted source adapter resolves the spec into an immutable source generation, records adapter-specific provenance, and materializes a complete task-private tree in the work plane. The first implemented adapter is Git and MUST create self-contained `.git` metadata that does not reference the gateway checkout, another task workspace, or an external shared Git directory.

The provider-neutral contract also admits future archive, generated, service-produced, or operator-imported source kinds without changing task, workspace, result, or publication identity. Host paths remain deferred. A future host-path adapter must capture an immutable generation before execution; it must not mount a live operator directory into a task or let the model name arbitrary paths.

The source adapter may use a broker-owned immutable baseline, sanitized bundle/archive, or broker-local mirror internally. The activated task always receives a private view with one writer lease. Copy-on-write, reflinks, or later content-addressed storage may reduce duplication without changing this contract.

**Alternative considered:** define Project as Git and add unrelated workspace types later. Rejected because task identity, lifecycle, output, review, and publication apply to more than repositories; Git history and changed paths are provider-specific provenance.

**Alternative considered:** mount a linked host worktree. Rejected because its `.git` file points to shared gateway-owned metadata and reintroduces host paths, shared mutable state, and credential coupling.

### 3. Exclude acquisition credentials by construction

Project source configuration contains a logical source identifier, not a model-supplied URL or credential. Trusted Nix/provider configuration maps it to an acquisition adapter. For private sources, that adapter may exercise an operator credential while fetching into detached broker-owned staging, but credential-bearing environment, arguments, helpers, remotes, and logs must be confined to that adapter and destroyed before the source generation becomes executable.

The executable source tree, provider configuration, guest environment, VM disk/snapshots, task metadata, logs, and frozen outputs must not receive adapter-owned credential material or host-only acquisition paths. Materialized Git remotes and helper configuration are removed or rewritten before activation. Ordinary commands inside the guest have no ambient push or fetch credential. Any later authenticated publication is a separate trusted operation with its own approval and target binding.

This is a construction and bounded-verification claim, not a universal byte-absence proof: an arbitrary repository may independently contain bytes equal to a secret, encoded copies, or encrypted data. Exact-value scanning of representative surfaces is useful defense in depth and regression detection, but `assertSanitized` must not claim to prove that arbitrary source content contains no credential material.

### 4. Treat source and workspace generations as immutable provenance

The provider assigns an opaque source generation to the exact materialized baseline and records the Project and source generation in the task-run worker specification. The task workspace receives its own workspace ID and active lease.

A retry receives a new run and workspace binding. It may deliberately reuse the same immutable source generation, but stale operations from the prior run remain fenced. Changing Project source configuration or selected revision creates a new source generation; it never mutates the meaning of an active binding.

The provider records sufficient provenance to reproduce or audit materialization without exposing host paths or credentials: Project ID, source kind, source revision/content identity where available, adapter revision, source-generation ID, workspace ID, lease ID, lane, task/run, timestamps, and lifecycle state.

### 5. Separate direct Project permission from publication

Effective Project permission is the lesser of the lane maximum and the Project's `laneAccess` value:

- `read-only`: the work plane is read-only; output remains writable.
- `workspace-write`: the task may modify only its private work plane and output.

Neither permission grants merge, push, canonical-checkout mutation, credentials, or publication. Completion may produce ordinary human artifacts and a Project-result descriptor containing the baseline generation and result identity. A later reviewed operation can promote that result, generate a patch/bundle, or create another Project generation.

A worker request to push or mutate the canonical source without an explicit publication capability fails rather than acquiring ambient credentials.

### 6. Resolve the provider only through the frozen lane binding

The `broker-project` provider accepts trusted control-plane facts from `add-explicit-worker-lanes`: board-qualified task/run, lane revision, Project/source declaration, effective permission, policy digest, and resource ceilings. The ordinary workspace or execution protocol does not accept caller-selected Project IDs, sources, revisions, providers, host paths, mount layouts, or permissions.

Activation is fail-closed and idempotent for the same complete binding. Conflicting facts for the same environment or task run fail without replacing the active workspace. Partial materialization remains detached from execution and is cleaned or reconciled after a crash.

### 7. Mount all planes through one logical workspace binding

The broker owns physical storage and mounts the three planes through Gondolin's mediated VFS. Hermes receives `/workspace/work` as the trusted worker CWD and `/workspace` as the logical root. Terminal, execute-code, file, search, patch, process, and completion operations resolve paths through the same task-run binding.

Path handling must distinguish:

- operations rooted in mutable `work`;
- read-only `inputs` managed by the later input provider;
- output selection rooted strictly in `output`.

No surface rewrites a host path into the guest or derives a separate workspace from profile, conversation, CWD, or model arguments.

### 8. Reuse broker staging mechanics without weakening caller policy

Project source materialization and existing handoff/branch copying need similar detached staging, atomic installation, recovery, and cleanup mechanics. These mechanics should be shared internally where practical, but source selection and validation remain caller-specific:

- Project materialization validates a trusted Project source generation and permits ordinary repository symlinks within the private tree.
- Artifact capture validates the restricted output tree and rejects unsafe entries according to the handoff policy.
- Conversation branching copies the complete allowed working tree under its own authority contract.

There is no model-facing generic copy route.

### 9. Make lifecycle and resource ownership explicit

A Project workspace progresses through durable creation, active lease, release/finalization, retention, and deletion states. Creation stages detached storage before publishing one workspace record and lease. Execution begins only after source materialization and authority registration both succeed.

The workspace service must reconcile:

- abandoned staging after a crash;
- a durable workspace without a valid active lease;
- a stale lease after retry or task termination;
- interrupted release or deletion;
- retained Project results and output handoffs still referenced by downstream work.

Nix policy supplies workspace count, source size, file/entry limits, materialization deadline, retention, and storage quota. Disk ceilings must be enforced by storage/filesystem mechanisms where available rather than claimed from byte accounting alone.

### 10. Freeze provider-neutral Project results before deleting mutable work

Successful completion of a writable Project computes a provider-neutral result from the immutable baseline and the final private work tree. The result records task/run, lane, Project, source generation, result identity, provider revision, selected human artifacts, and optional adapter-specific metadata. For Git this may include commits, a bundle, patch/delta, changed paths, and history provenance; those fields are not required of non-Git providers.

Completion must durably freeze the selected source-relative delta or equivalent immutable result before releasing the writer lease. The mutable task workspace is never the long-term result. Once result capture and ordinary output capture succeed, the workspace transitions through release and physical deletion according to explicit retention and reference policy. Completion fails or remains recoverable if result freezing cannot finish; it must not report success and leave an unowned mutable workspace as the only copy.

Recording or delivering a result does not imply that the canonical Project changed. Publication is a separate trusted adapter operation bound to the immutable result and an expected destination generation. A later task may also consume a reviewed immutable result or selected output without receiving the producer's mutable workspace.

### 11. Enforce projected physical storage at materialization

Source-generation logical limits and workspace physical allocation are separate invariants. Reusing one ready source generation for concurrent tasks must still reserve or verify enough physical capacity for every task-private workspace before staging or installation begins. The provider records the reservation with the materialization operation, consumes it atomically on install, and releases it on abort or deletion.

Counting existing source-generation bytes once is insufficient when each materialization copies those bytes. Reflinks, snapshots, or deduplicated baselines may reduce actual allocation, but policy must use a conservative filesystem/storage reservation unless the backing mechanism supplies enforceable accounting.

## Risks / Trade-offs

- **[Risk] Full private repositories consume storage and clone time.** → Start with the correctness-first contract; add broker-local baselines, reflinks, snapshots, or CAS only behind the same provider semantics.
- **[Risk] Private-source credentials leak through Git configuration or logs.** → Acquire sources only in trusted adapters, sanitize remotes/config, scan representative materializations, and test environment/argv/log/output absence.
- **[Risk] Read-only work is accidentally writable through another surface.** → Enforce permission in the broker/VFS and exercise terminal, file, patch, symlink, process, and stale-handle paths.
- **[Risk] Output and repository result are conflated.** → Keep `/workspace/output` as explicit human/data delivery and record Project-result provenance separately.
- **[Risk] Existing prompts assume the old workspace root.** → Update every prompt and tool path together, discard incompatible state, and retain no legacy alias.
- **[Risk] Provider staging diverges from existing handoff recovery.** → Extract only internal staging/install/reconciliation primitives with distinct policy entry points.
- **[Risk] Source-generation identity is too weak for reproducibility.** → Bind a trusted source revision/content identity and adapter revision; do not infer identity from mutable branch names alone.

## Implementation Order

1. Complete `add-explicit-worker-lanes` and the narrowed `add-task-workspace-handoff`.
2. Add Nix Project source adapters, provider selection, credentials, and hard limits.
3. Extend broker storage and lifecycle records with Project/source-generation provenance and detached materialization states.
4. Implement broker-owned source acquisition and sanitized standalone repository materialization.
5. Create and mount the three workspace planes; make `/workspace/work` the trusted CWD across every Hermes surface while preserving handoff capture at `/workspace/output`.
6. Implement read-only and workspace-write enforcement plus Project-result metadata without publication authority.
7. Update prompts and acceptance tools for the new workspace layout.
8. Discard incompatible broker workspaces and task data; retain no compatibility path.
9. Smoke-test public/private source materialization, credential absence, Git status, writes, read-only review output, immutable output capture, retry fencing, crash recovery, cleanup, and one-workspace identity.
10. Enable `add-multi-task-inputs` only after the empty read-only inputs plane and lifecycle contract pass.

## Open Questions

The first source adapter and baseline-storage optimization are implementation choices, but they must satisfy the standalone-repository, credential-hygiene, immutable-generation, and no-host-path requirements above. CAS/Merkle storage remains a deferred optimization documented in the handoff design's Ideas section.
