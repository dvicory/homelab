# kanban-sandbox-workspace Specification

## Purpose

Define trusted Kanban workspace acquisition, the durable `/workspace/output` handoff boundary, task-run fencing, parent dependency isolation, selected-artifact materialization and human delivery, and broker outage and rollback behavior for QA Gondolin Kanban tasks.
## Requirements
### Requirement: Trusted Kanban workspace acquisition

When the QA Gondolin backend is selected, trusted Kanban claim/dispatch code MUST acquire or reuse a broker workspace derived from trusted task identity and pass only opaque workspace and lease references to the matching worker. The worker MUST expose `/workspace/output` as the sole durable cross-task output subtree; paths outside it are scratch and MUST NOT be captured. Model-facing Kanban arguments MUST NOT select a workspace ID, lease ID, handoff ID, host path, provider, or output root.

#### Scenario: First task claim

- **GIVEN** a claimed QA Kanban task
- **WHEN** a registered Gondolin worker lane prepares the task
- **THEN** trusted infrastructure SHALL acquire or reuse a private workspace under task-scoped broker authority
- **AND** SHALL pass returned opaque workspace and lease IDs only to the matching worker process
- **AND** SHALL provide guest `/workspace` with its durable output subtree at `/workspace/output`

#### Scenario: Model supplies workspace or output selection

- **WHEN** model-generated Kanban arguments contain a workspace ID, lease ID, handoff ID, provider, host path, or output-root selector
- **THEN** Hermes MUST ignore or reject those fields
- **AND** MUST NOT forward them to the broker control plane

### Requirement: Consistent worker filesystem binding

A Gondolin Kanban worker's terminal and environment-backed file surfaces MUST use its task workspace binding and guest path `/workspace`. Hermes MAY bridge an upstream per-session CWD through `session_context`/`runtime_cwd`, but per-session CWD is a logical runtime-directory facility, not workspace authority or host-path disclosure. For a Gondolin Kanban worker, trusted dispatch MUST strip upstream host scratch and host process CWD and expose only guest `/workspace`. Hermes MUST NOT present a gateway host worktree as the sandbox workspace.

#### Scenario: Worker environment

- **GIVEN** a claimed task with a broker workspace binding
- **WHEN** Hermes launches its worker
- **THEN** the worker SHALL receive `HERMES_WORKSPACE_ID`, `HERMES_WORKSPACE_LEASE_ID`, and `HERMES_WORKSPACE_GUEST_PATH=/workspace`
- **AND** SHALL receive a durable `/workspace/output` subtree for handoff
- **AND** SHALL NOT receive the broker host path or upstream Kanban scratch path through its environment or process CWD

#### Scenario: Terminal reuse

- **GIVEN** a worker that has written a file through Gondolin
- **WHEN** a later terminal or file tool call resolves the same task
- **THEN** it SHALL resolve the same workspace and active lease
- **AND** files outside `/workspace/output` SHALL remain task scratch rather than handoff data

### Requirement: Automatic frozen output capture

A successful broker-backed completion MUST invoke the required finalizer and capture exactly `/workspace/output`. Every model-facing `artifacts` entry MUST be an explicitly selected normalized relative path naming one regular file under the trusted task workspace and below `output/`. Kanban MUST perform syntax-only validation before the broker call and MUST NOT infer paths from summary/result prose or subscriptions.

The capture request MUST contain exactly `finalizationId`, trusted `environmentKey`, `taskId`, `runId`, and `selectedArtifacts`. The broker MUST validate the live tree and selections, fence the exact run, close and drain the VM, copy and validate detached storage, and return one immutable ready handoff with the selected-artifact manifest. Kanban MUST remain `running` until that response exists and every selected file has been idempotently materialized into native task attachment storage. Native scratch, directory, and worktree completion MUST continue to materialize selected files into native attachment storage before `done`.

#### Scenario: Task completion with output

- **GIVEN** a claimed broker-backed worker produced valid files under `/workspace/output` and selected normalized relative artifacts
- **WHEN** Kanban accepts completion metadata and invokes the required finalizer
- **THEN** the broker SHALL validate the selected files and capture exactly `/workspace/output` in one operation
- **AND** SHALL revoke the writer before copying and atomically freeze the output subtree
- **AND** Kanban SHALL transition to `done` only after the ready handoff and every selected native attachment are durable

#### Scenario: Prose-only completion

- **GIVEN** a broker-backed task completes with empty output and no selected artifacts
- **WHEN** the finalizer runs
- **THEN** the broker SHALL consume the run and create an empty immutable handoff
- **AND** no other workspace path SHALL be captured

#### Scenario: Completion metadata is rejected before fencing

- **GIVEN** an artifact path is absolute, traversal-based, host-derived, malformed, outside `output/`, or a symlink escape
- **WHEN** Kanban validates completion
- **THEN** it MUST reject before invoking broker capture
- **AND** the task SHALL remain `running` with its writer lease active
- **AND** it MUST NOT infer a replacement path from summary or result prose

#### Scenario: Broker preflight failure remains recoverable

- **GIVEN** the fixed live output or a selected path contains an unsafe node, unreadable entry, or four-limit violation
- **WHEN** broker preflight runs before activation consumption
- **THEN** completion MUST fail while Kanban remains `running`
- **AND** the active run, lease, and VM SHALL remain available for correction
- **AND** no entry may be silently removed to satisfy validation

#### Scenario: Structurally bad fenced output

- **GIVEN** preflight passed but the source changed during fencing or detached validation finds an unsafe node, identity mismatch, unreadable file, or four-limit excess
- **WHEN** finalization continues
- **THEN** no ready handoff MAY be published
- **AND** the broker SHALL retain failure accounting
- **AND** Kanban SHALL not transition to `done`

### Requirement: Completion response loss and journal replay

Kanban and the broker MUST bind one finalization ID to the exact frozen board, task, run, worker lane, policy, workspace, lease, fixed output source, and ordered selected-artifact set. The broker MUST persist the finalization journal before filesystem mutation. Identical replay MUST resume or return the same operation, using the journal rather than requiring an active source after activation consumption. Changed bound facts MUST conflict. A deliberate fresh producer attempt MUST receive a fresh globally unique run ID and finalization ID.

#### Scenario: Response loss before fencing

- **GIVEN** the client received no response and the broker has not staged or consumed the capture operation
- **WHEN** recovery repeats the same finalization ID and bound request while the source run remains active
- **THEN** the broker MAY preflight and fence the source at most once
- **AND** Kanban SHALL remain `running` until a ready handoff exists
- **AND** no empty substitute or producer redispatch SHALL occur

#### Scenario: Response loss after fencing

- **GIVEN** the broker consumed the activation and revoked the writer but the response was lost
- **WHEN** recovery repeats the identical finalization ID and request
- **THEN** the broker SHALL resume or return the journaled operation without active-source validation
- **AND** a ready result SHALL identify the same opaque handoff and selected-artifact manifest
- **AND** it MUST NOT create a second handoff or redispatch the producer

#### Scenario: Transient post-fence retry

- **GIVEN** fencing completed but copy, detached validation, fsync, rename, or native materialization failed transiently
- **WHEN** trusted recovery retries the same finalization operation
- **THEN** the broker and Kanban SHALL retain and retry the journaled operation without reopening the old activation
- **AND** Kanban SHALL remain non-done under existing lifecycle handling
- **AND** a deliberate fresh producer attempt SHALL use a fresh run and finalization ID

### Requirement: Two-phase output structure validation

The broker MUST validate the fixed output subtree and every selected artifact before and after fencing. It MUST enforce exactly `maxLogicalBytes`, `maxEntries`, `maxFileBytes`, and `maxPathBytes`; reject malformed names, absolute or traversal paths, NUL, invalid UTF-8, normalization collisions, symlinks, disallowed hardlinks, special files, unreadable entries, filesystem crossings, and limit excess; and never silently delete, skip, rewrite, or hide an entry. Sparse files MUST count by logical size.

Detached copying MUST preserve no mutable file identity or host ownership, ACL, or extended-attribute state and MUST publish no partial tree. Structural checks and byte-copy errors are the complete validation surface; the broker MUST NOT scan contents for secrets, malware, policy strings, or semantic validity.

#### Scenario: Safe tree is frozen atomically

- **GIVEN** the detached tree contains only allowed nodes and is within all four limits
- **WHEN** structural validation and fsync complete
- **THEN** the broker SHALL atomically install the destination temporary into ready handoff storage
- **AND** later writes or retries against the task workspace SHALL NOT change the frozen handoff

#### Scenario: Live preflight rejects output

- **GIVEN** live output or a selected path is structurally unsafe or exceeds a wired limit
- **WHEN** broker preflight runs
- **THEN** capture MUST fail before activation consumption
- **AND** the active run, lease, and VM SHALL remain recoverable

#### Scenario: Detached validation rejects output

- **GIVEN** the writer was fenced but detached validation finds an unsafe change or limit violation
- **WHEN** finalization continues
- **THEN** no ready handoff MAY be published
- **AND** Kanban SHALL remain non-done while the broker retains failure accounting

### Requirement: Retry, block, and reclaim lifecycle

Retries of one Kanban task MUST reuse retained mutable workspace only after trusted dispatch activates a fresh globally unique run against the frozen worker binding and supersedes the prior activation. Successful completion, block, timeout, and reclaim MUST consume or supersede the active broker activation before VM close. A late old-run execution or file request MUST fail even when task identity or a retained lease is known. Concurrent child tasks MUST receive distinct task-scoped workspaces. Reclaim uses existing upstream operator lifecycle and MUST NOT capture or deliver workspace data.

#### Scenario: Task retry

- **GIVEN** a failed worker attempt with retained workspace files and no active run
- **WHEN** the dispatcher starts a later attempt for the same task
- **THEN** it SHALL reacquire or reuse that task's workspace under a fresh run activation
- **AND** the later VM SHALL observe retained files
- **AND** any prior ready handoff SHALL remain unchanged

#### Scenario: Block consumes before close

- **GIVEN** an active run is blocked or times out while its VM remains live
- **WHEN** trusted lifecycle handles the block
- **THEN** it SHALL consume or supersede the activation before closing the VM
- **AND** the old run SHALL be stale before a close race can recreate it

#### Scenario: Operator reclaim consumes before close

- **GIVEN** an active Kanban run with a retained broker workspace
- **WHEN** a trusted operator uses the existing reclaim operation
- **THEN** upstream lifecycle MAY terminate and requeue the live run only after broker activation consumption or supersession
- **AND** reclaim MUST NOT capture, deliver, or copy workspace data
- **AND** a later attempt MUST obtain a fresh broker task-run activation

#### Scenario: Concurrent children

- **GIVEN** a parent task with two concurrently runnable child tasks
- **WHEN** both are dispatched under Gondolin
- **THEN** each child SHALL receive a distinct task-scoped workspace and independent lease
- **AND** neither workspace SHALL contain parent files merely because of the dependency edge

### Requirement: Broker outage and in-process recovery

When the QA Gondolin backend is configured, transient broker liveness MUST NOT remove terminal or file schemas from the Hermes model tool catalogue. Every workspace-backed execution surface, including terminal, file tools, process control, close-terminal, and execute-code, MUST revalidate through the trusted workspace pre-tool gate. Broker recovery MUST NOT require a Hermes process restart. Activation, capture, selected-artifact reads, and native materialization MUST fail closed or remain retryable without substituting a live VM, host path, empty handoff, local execution, Docker, Podman, or shared spool.

#### Scenario: Conversation starts during broker outage

- **GIVEN** the QA Gondolin broker or protected local UDS is unavailable
- **WHEN** Hermes creates a new conversation
- **THEN** workspace-backed tool schemas SHALL remain available
- **AND** attempts to use them SHALL fail before execution with a structured workspace-unavailable reason
- **AND** Hermes SHALL NOT invoke local, Docker, Podman, execute-code, process, host-scratch, or other fallback
- **AND** the reason SHALL distinguish broker reachability from workspace persistence and provide retry guidance without requiring a fresh conversation or Hermes restart

#### Scenario: Broker recovers in process

- **GIVEN** a conversation whose workspace-backed tool call, capture, or materialization was blocked while the broker was unavailable
- **WHEN** the broker and protected local UDS become available again
- **THEN** the next workspace-backed operation SHALL reacquire, revalidate, or resume its bound journaled operation
- **AND** execution or finalization SHALL resume without restarting Hermes, toggling tools, creating another conversation, or redispatching completed producer work

### Requirement: Handoff gate, transport, reset, and rollback

Task-run activation, capture, and `artifacts/read` MUST exist only on the authenticated control listener over the protected local UDS when the handoff gate is enabled. With the gate disabled, those routes, handoff root and schema initialization, policy actions, and migration behavior MUST be absent. The execution listener MUST have none of these routes and MUST disclose no handoff ID, broker root, or content path. No authenticated remote HTTPS handoff contract is provided.

#### Scenario: Gate-disabled routes and storage

- **GIVEN** workspace handoff is disabled
- **WHEN** NixOS and Home Manager configurations evaluate and the broker starts
- **THEN** activation, capture, `artifacts/read`, handoff root, schema, migration, policy action, and storage operation SHALL be absent
- **AND** ordinary workspace behavior SHALL remain unchanged

#### Scenario: QA reset and fresh cycle

- **GIVEN** QA acceptance requests a destructive reset
- **WHEN** operators stop the QA gateway, both broker sockets, and broker service
- **THEN** they SHALL verify and quarantine the whole canonical `/var/lib/hermes-qa-sandbox` state directory rather than edit a database or selected handoff tree
- **AND** SHALL recreate an empty mode-`0700` state directory before restarting QA
- **AND** SHALL verify fresh activation, capture, selected-artifact materialization, and ordinary attachment inspection before deleting quarantine

#### Scenario: Rollback has no production impact

- **GIVEN** the QA gate is disabled or the preceding QA generations are restored
- **WHEN** QA services and sockets are restarted
- **THEN** handoff routes and storage SHALL remain absent
- **AND** production Hermes services, production state, rootless Podman storage, and gateway credentials MUST remain untouched

### Requirement: Backend compatibility

The workspace integration MUST be gated to the Gondolin secure-terminal backend. Existing local, Podman, production, and non-sandbox worker workspace behavior MUST remain unchanged.

#### Scenario: Non-Gondolin worker

- **GIVEN** a task dispatched by a profile or lane not using Gondolin
- **WHEN** worker environment variables are prepared
- **THEN** Hermes SHALL retain its existing workspace behavior
- **AND** SHALL NOT call Gondolin workspace, handoff, import, export, or private-copy control routes

#### Scenario: Registered external Codex lane

- **GIVEN** QA Gondolin handoff is enabled and a task selects a registered external Codex lane
- **WHEN** the dispatcher prepares and spawns that task
- **THEN** the lane SHALL receive its existing host-visible task worktree, not guest-only `/workspace`
- **AND** no broker activation, capture, import, export, or workspace-preparation hook SHALL run
- **AND** deployment MUST NOT claim Gondolin isolation for that process

### Requirement: Parent dependencies do not imply artifact inputs

A `parents` edge MAY carry ordinary task status, summary, metadata, and comments, but MUST NOT mount, copy, retrieve, publish, or expose parent workspace files to the child. Each broker-backed child MUST acquire its own task-scoped workspace identity. File inputs require a separate explicit immutable artifact-input contract.

#### Scenario: A dependent child starts after its parent

- **GIVEN** a parent completes with a selected artifact and a child depends on that parent
- **WHEN** the child broker workspace is acquired
- **THEN** the child SHALL receive its own task-scoped workspace
- **AND** the parent artifact SHALL NOT appear in that workspace merely because of the dependency edge
- **AND** Hermes MUST NOT copy, retrieve, publish, or summarize the file as a substitute for an explicit artifact-input contract

### Requirement: Human delivery uses frozen selected artifacts

For broker-backed tasks, Hermes MUST read only paths in the ready handoff's selected-artifact manifest through the protected local control UDS. The read request MUST contain exactly hidden `handoffId` and normalized `relativePath`. Before transitioning the task to `done`, Hermes MUST idempotently materialize every selected file through upstream native task attachment storage, independent of recipient subscriptions. A completed task's selected files MUST therefore be available through ordinary task attachment inspection even when no platform recipient exists. Subscriptions MAY identify recipients and channels but MUST NOT identify or infer files.

Task/file materialization and recipient/attachment upload MUST be distinct durable stages. Materialization failure MUST keep the task in its existing `running` state and MUST remain retryable from the ready handoff without redispatching producer work. Upload failure MUST leave that recipient and attachment outstanding and MUST NOT advance its completion-event subscriber cursor. Retry MUST target only outstanding deliveries. A successful or ambiguously timed-out platform call MAY be delivered more than once when the platform has no idempotency key; the system MUST NOT claim exactly-once delivery.

Ordinary attachment inspection MUST remain side-effect-free by default. Only an explicit human request MAY select its `deliver` action for an already completed task. Hermes MUST resolve the selected native attachment paths inside the trusted gateway and MUST NOT expose those paths to the model, create another attachment row, recreate bytes, read the broker or live worker workspace, or rerun the task. When broker-completion attachments exist and no filenames are specified, re-delivery MUST prefer that authoritative set over later manual attachments.

#### Scenario: Selected artifact delivery

- **GIVEN** a running task has a ready handoff with a selected regular file
- **WHEN** Hermes finalizes completion
- **THEN** it SHALL read the exact frozen file over the local UDS
- **AND** SHALL store it idempotently through native task attachment storage before `done`
- **AND** ordinary task attachment inspection SHALL expose the selected attachment without requiring a recipient subscription
- **AND** Hermes MUST NOT read the live workspace or infer additional files

#### Scenario: Local materialization fails

- **GIVEN** a selected artifact has not reached native task attachment storage
- **WHEN** broker read or local storage fails
- **THEN** the task MUST remain `running`
- **AND** retry MUST resume from the ready handoff without redispatching producer work

#### Scenario: One of several uploads fails

- **GIVEN** one completed task has multiple recipient and attachment deliveries
- **WHEN** some succeed and one fails
- **THEN** retry SHALL preserve successful acknowledgements and retry only outstanding deliveries
- **AND** the failed delivery MUST NOT be reported as delivered

#### Scenario: Platform timeout is ambiguous

- **GIVEN** a platform accepted a document but its response was lost
- **WHEN** Hermes retries the outstanding delivery
- **THEN** a duplicate MAY occur if the platform lacks an idempotency key
- **AND** the system MUST document at-least-once rather than claim exactly-once behavior

#### Scenario: Human requests an existing attachment again

- **GIVEN** a completed task exposes broker-selected files through native attachment storage
- **WHEN** the human explicitly asks Hermes to send those existing attachments again
- **THEN** the existing attachment inspection tool SHALL request native delivery from durable storage without exposing a host path
- **AND** it MUST NOT create attachment rows, recreate bytes, access a worker workspace, or rerun the task
- **AND** ordinary attachment listing without the explicit delivery action SHALL remain side-effect-free

### Requirement: Explicit immutable input binding
Trusted workspace activation MUST resolve every `inputs_from` edge to one exact ready same-board handoff, validate the selected lane's effective input ceilings, acquire durable retention references, and bind all prepared inputs atomically with the destination task-run workspace authority. Each input MUST appear read-only at `/workspace/inputs/<producer-task-id>` and MUST remain distinct from destination work and output.

#### Scenario: Destination with no filesystem inputs
- **WHEN** a runnable task has no `inputs_from` edges
- **THEN** `/workspace/inputs` SHALL be an empty read-only broker-managed plane

#### Scenario: Destination with multiple inputs
- **WHEN** a runnable task has multiple valid prepared input bindings
- **THEN** workspace activation SHALL expose all exact producer handoffs in separate task-ID namespaces
- **AND** execution MUST NOT begin with a partial input set

#### Scenario: Input binding conflict
- **WHEN** activation facts differ from the persisted destination input generation or prepared broker operation
- **THEN** activation MUST fail as a stable conflict
- **AND** it MUST NOT substitute newer producer output, a live workspace, an empty directory, or a local path

### Requirement: Input lifecycle is independent from destination output
Input mounts MUST remain immutable for the destination run and MUST NOT be captured as destination output automatically. Completion MUST continue to freeze only `/workspace/output`; a worker must copy or synthesize selected input data into its own output deliberately.

#### Scenario: Destination completes without copying input
- **WHEN** a destination reads an input but writes no corresponding file under `/workspace/output`
- **THEN** completion SHALL NOT include the input file in the destination handoff

#### Scenario: Destination copies transformed input
- **WHEN** a destination writes a transformed input-derived file under `/workspace/output`
- **THEN** completion MAY freeze that destination-owned file
- **AND** provenance SHALL continue to identify the immutable inputs bound to the destination run

