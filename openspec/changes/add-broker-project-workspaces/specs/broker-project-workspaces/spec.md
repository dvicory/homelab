## ADDED Requirements

### Requirement: Trusted provider-neutral Project materialization
A broker Project provider MUST resolve only a Nix-authoritative logical Project, typed `SourceSpec`, immutable source generation, registered lane, and frozen task-run binding. It MUST dispatch the source kind to a trusted adapter and materialize a task-private self-contained source tree before guest execution. It MUST NOT accept a model-selected source identifier, repository URL, revision, provider, credential, permission, workspace, mount, or host path. Git MUST be the first supported adapter; future source kinds MUST preserve the same task, workspace, provenance, lifecycle, and result contract.

#### Scenario: Compatible Project task
- **WHEN** trusted dispatch supplies a complete task-run binding whose lane provider and source adapter support the Project source kind and effective permission
- **THEN** the broker SHALL resolve one immutable source generation and materialize it into a private task workspace
- **AND** execution SHALL begin only after materialization, lease acquisition, and sandbox-authority registration succeed

#### Scenario: Caller selects source mechanism
- **WHEN** an ordinary caller supplies a source identifier, URL, revision, provider, credential, permission, workspace, mount definition, or host path
- **THEN** the provider MUST reject or ignore the field
- **AND** it MUST NOT create partial executable authority

#### Scenario: Future host-path source
- **WHEN** a future trusted adapter imports an operator-declared host directory
- **THEN** it SHALL capture an immutable source generation before task execution
- **AND** it MUST NOT expose a live bind mount or accept a model-selected path

### Requirement: Canonical three-plane workspace
Every newly activated broker task workspace MUST expose mutable work at `/workspace/work`, broker-managed read-only inputs at `/workspace/inputs`, and task-owned output at `/workspace/output`. The worker CWD and ordinary relative paths MUST begin in `/workspace/work`.

#### Scenario: Project worker layout
- **WHEN** a broker Project workspace is activated
- **THEN** the private Project source SHALL appear at `/workspace/work`
- **AND** `/workspace/inputs` SHALL be read-only and empty unless trusted input bindings exist
- **AND** `/workspace/output` SHALL be writable within output limits
- **AND** the worker CWD SHALL be `/workspace/work`

#### Scenario: Legacy root path
- **WHEN** a worker assumes its mutable work root is `/workspace` rather than `/workspace/work`
- **THEN** the system MUST NOT supply a compatibility symlink, duplicate mutable mount, or dual-layout resolver

### Requirement: External worker completion is mediated
An external Codex worker MUST run with CWD `/workspace/work` and MUST NOT receive Kanban lifecycle or direct broker-finalization authority. Its structured result MUST support an explicit `artifacts` array containing only normalized workspace-root paths below `output/`. The trusted wrapper MUST validate that array and invoke Kanban completion with it. CWD-relative traversal forms such as `../output/report.md`, changed Git paths, summaries, result prose, and directory discovery MUST NOT select artifacts.

The broker MUST freeze the complete `/workspace/output` tree for downstream task inputs independently of the selected human-artifact subset. The wrapper and Kanban completion path MUST use the same frozen task-run binding as terminal, file, patch, process, and other worker surfaces.

#### Scenario: Codex selects a report
- **GIVEN** Codex runs in `/workspace/work` and writes `/workspace/output/review.md`
- **WHEN** its structured result selects `output/review.md`
- **THEN** the trusted wrapper SHALL pass that selection to Kanban completion
- **AND** handoff capture and native task attachment materialization SHALL follow the ordinary broker-backed completion contract

#### Scenario: Codex reports changed repository files
- **GIVEN** Codex changes files below `/workspace/work`
- **WHEN** the wrapper records Git changed paths or Codex mentions paths in prose
- **THEN** those paths SHALL remain Project-result metadata
- **AND** they MUST NOT become human artifacts unless Codex separately selects normalized paths below `output/`

#### Scenario: Codex attempts its own terminal transition
- **WHEN** external Codex attempts to call Kanban completion or broker finalization directly
- **THEN** the operation MUST be unavailable or denied
- **AND** the trusted wrapper SHALL remain the sole owner of the task's terminal transition

### Requirement: Adapter-specific metadata remains self-contained
A materialized Project workspace MUST contain all mutable source metadata inside that task-private work plane and MUST NOT reference the gateway checkout, another task workspace, or a shared external metadata directory. The Git adapter MUST create self-contained task-private `.git` metadata. Internal baseline, reflink, snapshot, or content-addressed optimizations MUST preserve this visible contract for every source kind.

#### Scenario: Inspect Git task repository
- **WHEN** a worker inspects `.git` and repository configuration in `/workspace/work`
- **THEN** all writable Git metadata SHALL belong to that task workspace
- **AND** no Git path SHALL point to gateway or sibling-task storage

#### Scenario: Two concurrent Project tasks
- **WHEN** two tasks materialize the same Project source generation concurrently
- **THEN** each task SHALL receive an independent workspace and lease
- **AND** writes by either task MUST NOT change the other's files or source metadata

### Requirement: Acquisition credential confinement
Acquisition credentials MUST be exercised only inside trusted source adapters. Credential-bearing helpers, environment, arguments, remotes, configuration, and logs MUST be destroyed or rewritten before the source generation becomes executable and MUST NOT be forwarded to the guest, workspace metadata, VM disk or snapshot, task metadata, or frozen output. Exact-value scans MAY detect regressions but MUST NOT be represented as universal proof that arbitrary source content cannot independently contain matching or encoded bytes.

#### Scenario: Private Project acquisition
- **WHEN** a trusted adapter uses a credential to acquire a private source generation
- **THEN** the adapter SHALL produce an executable source tree without ambient acquisition or publication authority
- **AND** ordinary guest source operations SHALL receive no adapter credential

#### Scenario: Adapter confinement fails
- **WHEN** source materialization cannot remove credential-bearing helper state, environment, arguments, remotes, logs, or host-only paths from the executable generation
- **THEN** activation MUST fail before guest execution
- **AND** detached staging SHALL be quarantined or removed according to recovery policy

### Requirement: Immutable source-generation provenance
Every Project workspace binding MUST record an opaque source generation and sufficient trusted provenance to identify the Project, source revision or content identity, adapter revision, lane, board-qualified task/run, workspace, lease, permission, and lifecycle state without exposing credentials or host paths.

#### Scenario: Retry on unchanged source
- **WHEN** a task retries against the same immutable source generation
- **THEN** it MAY receive a new private workspace based on that generation
- **AND** the new run and lease MUST fence all operations from the prior run

#### Scenario: Project source changes
- **WHEN** the trusted Project revision or source configuration changes
- **THEN** new resolution MUST create or select a distinct source generation
- **AND** active bindings MUST retain their original immutable meaning

### Requirement: Project filesystem permission is not publication
Effective Project permission MUST be no greater than both the lane maximum and Project `laneAccess`. `read-only` MUST prevent work-plane mutation; `workspace-write` MUST permit mutation only inside the private work plane and output. Neither permission SHALL imply merge, push, canonical-source mutation, publication, or credential authority.

#### Scenario: Read-only review lane
- **WHEN** a review task resolves effective Project permission `read-only`
- **THEN** all terminal, file, patch, process, and indirect work-plane writes MUST fail
- **AND** the task MAY write its bounded report under `/workspace/output`

#### Scenario: Writable Project lane
- **WHEN** a Project task resolves effective permission `workspace-write`
- **THEN** it MAY modify its private `/workspace/work` and `/workspace/output`
- **AND** it MUST NOT mutate the canonical Project or another task workspace

#### Scenario: Guest attempts authenticated push
- **WHEN** a worker attempts to push without a separate trusted publication capability
- **THEN** the operation MUST lack ambient credentials and MUST NOT mutate an operator target

### Requirement: Single workspace across every worker surface
The worker process, terminal, execute-code, file, search, patch, process, and completion surfaces MUST consume the same task-run Project workspace and effective permission. No surface MAY substitute a gateway host worktree, profile CWD, conversation workspace, or local fallback.

#### Scenario: Cross-surface file observation
- **WHEN** a writable Project worker creates a file through one supported surface and reads it through another
- **THEN** both surfaces SHALL observe the same file in the same `/workspace/work` generation

#### Scenario: Broker workspace unavailable
- **WHEN** the resolved Project workspace or lease is unavailable
- **THEN** every workspace-bearing surface MUST fail closed with a stable reason
- **AND** none SHALL use the gateway checkout or local filesystem as fallback

### Requirement: Recoverable Project workspace lifecycle
Project materialization MUST use durable lifecycle facts, detached staging, atomic installation, active writer leases, release/finalization, retention, and deletion. Broker recovery MUST reconcile abandoned staging, incomplete installation, stale leases, interrupted release, and interrupted deletion without exposing partial storage to execution.

#### Scenario: Crash during materialization
- **WHEN** the broker restarts after source bytes were staged but before workspace installation and authority registration completed
- **THEN** recovery SHALL resume or remove the detached operation according to its durable state
- **AND** no worker SHALL execute against the partial tree

#### Scenario: Stale run after retry
- **WHEN** an old run invokes a workspace operation after a new run owns the task workspace generation
- **THEN** the broker MUST reject the stale operation without altering the active run

### Requirement: Materialization reserves physical storage
Before staging or installing a task-private workspace, the broker MUST reserve or verify projected physical capacity for that materialization independently of source-generation logical limits. Concurrent workspaces derived from one reusable source generation MUST each consume a conservative reservation unless the storage backend supplies enforceable shared-allocation accounting.

#### Scenario: Reused generation exceeds capacity
- **GIVEN** one source generation is already materialized for other active tasks
- **WHEN** another task would exceed the effective physical workspace quota
- **THEN** the new materialization MUST fail before installation
- **AND** it MUST NOT treat previously counted source-generation bytes as capacity for the additional workspace

#### Scenario: Materialization aborts
- **WHEN** a reserved materialization fails or is cancelled before installation
- **THEN** its physical reservation SHALL be released idempotently

### Requirement: Project completion freezes an immutable result and deletes mutable work
Successful writable completion MUST durably freeze a provider-neutral Project-result descriptor and selected source-relative delta or equivalent immutable result before releasing the writer lease. The result MUST bind the task/run, lane, Project, baseline source generation, result identity, provider revision, and selected human artifacts, with optional adapter-specific provenance. Recording or delivering it MUST NOT claim or perform canonical publication. The mutable workspace MUST transition through durable release and physical deletion once capture succeeds and retention/reference policy permits; it MUST NOT be the only retained copy of a completed result.

#### Scenario: Modified Git Project completion
- **WHEN** a writable Git Project task completes with changes in its private work plane
- **THEN** the system SHALL freeze a bounded immutable result that may include commits, bundle or patch/delta, changed paths, and Git provenance
- **AND** the canonical Project SHALL remain unchanged

#### Scenario: Result freezing fails
- **WHEN** output capture succeeds but immutable Project-result capture cannot complete
- **THEN** completion MUST remain failed or durably recoverable
- **AND** the system MUST NOT report success and delete the only mutable copy

#### Scenario: Result capture succeeds
- **WHEN** immutable output and Project-result capture are durable
- **THEN** the writer lease SHALL be released
- **AND** the mutable workspace SHALL be deleted according to explicit retention and reference policy

#### Scenario: Human patch delivery
- **WHEN** the task selects a patch below `/workspace/output` for human delivery
- **THEN** delivery SHALL use the frozen output handoff
- **AND** the patch selection MUST remain distinct from publication of the complete Project result
