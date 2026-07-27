# kanban-sandbox-workspace Specification

## Purpose

Define trusted workspace acquisition, the durable `/workspace/output` handoff boundary, worker binding, direct-child private copies, retry/block/reclaim fencing, explicit frozen-file delivery, and broker outage behavior for QA Gondolin Kanban tasks.

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

A successful broker-backed completion MUST invoke the required completion-finalizer and capture exactly `/workspace/output`. Empty output is valid for prose-only tasks. Kanban MUST validate the claimed run, broker-worker `artifacts`, and path-valued completion metadata before invoking the broker; each selected artifact MUST be a normalized relative regular file below `output/`. The broker capture request MUST contain only trusted `finalizationId`, `environmentKey`, `taskId`, and `runId` facts and MUST NOT accept an artifact list, model-selected root, host path, workspace ID, lease ID, or handoff ID.

The broker MUST preflight the source while the task-run activation and writer lease remain active, then consume the exact activation, revoke the writer, close the VM, drain VFS callbacks, copy the output subtree to broker-owned destination-temporary storage, validate the detached tree, fsync, atomically install one immutable frozen handoff, and assign an opaque handoff ID before Kanban marks the task `done`. Kanban remains in its existing `running` state until the ready handoff response. This capability MUST NOT add Kanban `finalizing` or `publication_failed` task statuses; those names, where present, describe workspace-operation recovery state only. The process MUST NOT capture the whole workspace, depend on canonical content comparison, or perform content scanning.

#### Scenario: Task completion with output

- **GIVEN** a task holding an active workspace lease and live VM with files under `/workspace/output`
- **WHEN** Kanban accepts completion metadata and invokes the required finalizer
- **THEN** the broker SHALL preflight and capture exactly `/workspace/output` in one capture call
- **AND** SHALL revoke the writer before copying and atomically freeze the output subtree
- **AND** Kanban SHALL transition to `done` only after ready handoff storage is durable

#### Scenario: Prose-only completion

- **GIVEN** a broker-backed task has no files under `/workspace/output`
- **WHEN** it reaches successful completion
- **THEN** the broker SHALL consume the run and finalize an empty output tree
- **AND** the task SHALL complete normally without capturing other workspace paths

#### Scenario: Completion metadata is rejected before fencing

- **GIVEN** `artifacts` or a path-valued completion field is absolute, host-derived, traversal-based, a URI/drive path, outside `output/`, a directory, or a symlink
- **WHEN** Kanban validates completion
- **THEN** it MUST reject before invoking broker capture
- **AND** the task SHALL remain `running` with its writer lease active
- **AND** no artifact selector SHALL enter the broker capture request

#### Scenario: Broker preflight failure remains recoverable

- **GIVEN** the fixed live output contains an unsafe node, unreadable entry, or a four-limit violation
- **WHEN** broker preflight runs before activation consumption
- **THEN** completion MUST fail while Kanban remains `running`
- **AND** the active run, lease, and VM SHALL remain available for correction
- **AND** no entry may be silently removed to satisfy validation

#### Scenario: Structurally bad fenced output

- **GIVEN** preflight passed but the source changed during fencing or the detached copy exposes an unsafe node, identity mismatch, unreadable file, or four-limit excess
- **WHEN** detached validation runs
- **THEN** no ready handoff MAY be published
- **AND** the broker operation SHALL retain `publication_failed`, `quarantined`, or `failed` state with temporary/failure accounting
- **AND** Kanban SHALL not transition to `done`

### Requirement: Completion response loss and journal replay

The broker MUST persist a finalization journal before filesystem mutation and bind each finalization ID to the trusted source activation, task, run, environment, workspace, lease, policy decision, and fixed output source. Identical replay MUST return or resume the same operation. Once activation consumption is recorded, replay MUST use the journal and MUST NOT recheck the source as active. A changed bound fact MUST fail as an idempotency conflict. A deliberate fresh producer attempt MUST use a fresh run ID and fresh finalization ID.

#### Scenario: Response loss before fencing

- **GIVEN** the client received no response and the broker has not staged or consumed the capture operation
- **WHEN** recovery repeats the same finalization ID while the source run remains active
- **THEN** the broker MAY preflight and fence the source at most once
- **AND** Kanban SHALL remain `running` until a ready handoff exists
- **AND** no empty substitute or producer redispatch SHALL occur

#### Scenario: Response loss after fencing

- **GIVEN** the broker consumed the activation and revoked the writer but the response was lost
- **WHEN** recovery repeats the identical finalization ID and request
- **THEN** the broker SHALL resume or return the journaled operation without active-source validation
- **AND** a ready result SHALL identify the same opaque handoff
- **AND** it MUST NOT create a second handoff or redispatch the producer

#### Scenario: Transient post-fence retry

- **GIVEN** fencing completed but copy, detached validation, fsync, or rename failed transiently
- **WHEN** trusted recovery retries the same finalization operation
- **THEN** the broker SHALL retain and retry the journaled operation without reopening the old activation
- **AND** Kanban SHALL remain non-done under existing lifecycle handling
- **AND** a deliberate fresh producer attempt SHALL use a fresh run and finalization ID

### Requirement: Two-phase output structure validation

Before fencing, broker preflight MUST inspect `/workspace/output` and configured policy while the task remains `running`. It MUST reject traversal, absolute or host paths, empty segments, NUL, invalid UTF-8, normalization collisions, symlinks, disallowed hardlinks, sockets, devices, FIFOs, unreadable entries, source filesystem crossings, and excess of exactly `maxLogicalBytes`, `maxEntries`, `maxFileBytes`, or `maxPathBytes`. Sparse files count at logical size. Preflight failure MUST leave the active run and writer lease in place. No invalid entry may be silently deleted, skipped, or rewritten.

After fencing, the broker MUST copy only directories and regular files to a broker-owned destination temporary without following symlinks, crossing a source filesystem boundary, preserving hardlinks, or preserving host ownership/ACL/xattr state. It MUST validate the detached tree again, including node kind, independent destination identity, readability, normalized modes, and all four limits, and atomically rename only after successful fsync. Structural checks and byte-copy errors are the complete validation surface; the broker MUST NOT scan contents for secrets, malware, policy strings, or semantic validity.

#### Scenario: Safe tree is frozen atomically

- **GIVEN** the detached tree contains only allowed nodes and is within all four limits
- **WHEN** structural validation and fsync complete
- **THEN** the broker SHALL atomically install the destination temporary into ready handoff storage
- **AND** later writes or retries against the task workspace SHALL NOT change the frozen handoff

### Requirement: Direct-child source authority and private copy

A trusted direct child MAY inherit output only when Kanban records the task that created it as the sole source, the direct parent link remains present, source and destination share board and tenant, the source is `done` with one ready handoff, and both assignee policies permit private copy. Kanban MUST revalidate every fact on every import attempt, including replay after a preparation response loss. The model MUST NOT choose an arbitrary parent, dependency, task, workspace, lease, or handoff. Only after Kanban validation may trusted dispatch call the broker with derived source and destination IDs. The broker MUST bind those IDs to one preparation ID, copy the frozen source output into a new private writable workspace, and issue an independent lease.

#### Scenario: Authorized direct child

- **GIVEN** a same-board, same-tenant parent created a directly linked child and has a ready handoff
- **WHEN** Kanban revalidates the relation and trusted dispatch prepares the child
- **THEN** it SHALL create a durable preparation operation and private destination copy
- **AND** child mutation SHALL NOT change the parent frozen handoff or producer workspace

#### Scenario: Link or state mutation before import

- **GIVEN** preparation intent exists but the direct link was removed, board or tenant changed, source is no longer `done`, handoff is not ready, or policy changed
- **WHEN** Kanban validates immediately before import
- **THEN** it MUST reject before calling the broker
- **AND** the child SHALL remain blocked/non-runnable without an empty workspace or live-parent access

#### Scenario: Source not finalized

- **GIVEN** the source is not `done` under existing Kanban task state, has a failed workspace operation, is blocked, or is rejected, or lacks a ready handoff
- **WHEN** dispatch evaluates the child
- **THEN** the child SHALL remain non-runnable or explicitly dependency-blocked
- **AND** no empty workspace SHALL masquerade as the requested parent output

#### Scenario: Blocked or rejected reviewer

- **GIVEN** a reviewer/child is blocked or rejected because its source is not ready
- **WHEN** Kanban records the reviewer state
- **THEN** it SHALL not read the live parent workspace
- **AND** it SHALL not auto-promote, complete, capture, or deliver the parent draft
- **AND** reviewer state SHALL remain separate from parent task state

#### Scenario: Child completion captures changed output

- **GIVEN** a child owns a private writable copy at `/workspace/output`
- **WHEN** it edits or deletes files and completes successfully
- **THEN** its own completion SHALL automatically capture its changed output
- **AND** no explicit republication operation or model-facing output selector SHALL be available

### Requirement: Retry, block, and reclaim lifecycle

Retries of one Kanban task MUST reuse retained mutable workspace only after trusted dispatch activates a fresh run ID and supersedes the prior activation. Successful completion, block, timeout, and reclaim MUST consume or supersede the active broker activation before VM close. A late old-run request MUST fail even when task identity or a retained lease is known. Concurrent child tasks MUST NOT inherit one mutable workspace lease. Reclaim uses existing upstream operator lifecycle and MUST NOT capture, import, export, or deliver workspace data.

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
- **AND** reclaim MUST NOT capture, import, export, deliver, or copy workspace data
- **AND** a later attempt MUST obtain a fresh broker task-run activation

#### Scenario: Concurrent children

- **GIVEN** a parent task with two concurrently runnable child tasks
- **WHEN** both are dispatched under Gondolin
- **THEN** each child SHALL receive a distinct private workspace and independent lease

### Requirement: Human delivery uses explicit export tokens

For broker-backed tasks, upstream `artifacts` MUST remain the explicit selection of normalized relative regular files below `output/`; metadata and summary path-valued fields MUST reject absolute host paths and traversal before capture. Free-form summary prose is not a file selector and is not content-scanned. Subscription records MAY route recipients and channels, but MUST NOT name files or infer output. Hermes owns recipient/channel retry. Broker delivery MUST use exactly `exports/prepare`, `exports/read`, and `exports/release`: prepare authorizes a ready handoff and one relative file, read streams only an expiring opaque token, and release ends token use. Delivery MUST read the finalized handoff, never the live VM or mutable workspace, and MUST NOT use a shared spool.

The same HTTP contract MUST be used by the local authenticated UDS client and authenticated remote HTTPS client. Transport choice MUST NOT alter routes, schemas, authorization, or token ownership.

#### Scenario: Explicit delivery

- **GIVEN** a completed task has a ready handoff and explicit relative files below `output/`
- **WHEN** Hermes calls export prepare, read, and release
- **THEN** it SHALL read exactly those files from the frozen handoff
- **AND** it MUST NOT widen delivery to the directory or infer additional files

#### Scenario: Export token replay and expiry

- **GIVEN** an export token was released or expired
- **WHEN** a client replays read or release
- **THEN** the broker MUST reject the read and keep the token non-active
- **AND** the ready handoff and completed task SHALL remain valid

#### Scenario: Interrupted read

- **GIVEN** a recipient disconnects during a token stream
- **WHEN** Hermes handles the interrupted delivery
- **THEN** it SHALL release the token in cleanup and retain recipient retry state
- **AND** no live VM read or shared spool SHALL be treated as completed delivery

#### Scenario: Delivery failure

- **GIVEN** handoff capture succeeded but a recipient/channel is unavailable
- **WHEN** Hermes delivery fails
- **THEN** the task SHALL remain `done`
- **AND** the frozen handoff SHALL remain immutable and valid
- **AND** Hermes SHALL retry delivery independently of capture

### Requirement: Broker outage and in-process recovery

When the QA Gondolin backend is configured, transient broker liveness MUST NOT remove terminal or file schemas from the Hermes model tool catalogue. Every workspace-backed execution surface, including terminal, file tools, process control, close-terminal, and execute-code, MUST revalidate through the trusted workspace pre-tool gate. Broker recovery MUST NOT require a Hermes process restart. Capture, child preparation, and export operations MUST fail closed or remain retryable without substituting a live VM, host path, empty handoff, or shared spool.

#### Scenario: Conversation starts during broker outage

- **GIVEN** the QA Gondolin broker and its sockets are stopped
- **WHEN** Hermes creates a new conversation
- **THEN** workspace-backed tool schemas SHALL remain available
- **AND** attempts to use them SHALL fail before execution with a structured workspace-unavailable reason
- **AND** Hermes SHALL NOT invoke local, Docker, Podman, execute-code, process, host-scratch, or other fallback
- **AND** the reason SHALL distinguish broker reachability from workspace persistence and provide retry guidance without requiring a fresh conversation or Hermes restart

#### Scenario: Broker recovers in process

- **GIVEN** a conversation whose workspace-backed tool call was blocked while the broker was unavailable
- **WHEN** the broker and its sockets become available again
- **THEN** the next workspace-backed tool call SHALL reacquire or revalidate its binding
- **AND** execution SHALL resume without restarting Hermes, toggling tools, or creating another conversation

### Requirement: Handoff gate, transport, reset, and rollback

Capture, import, `exports/prepare`, `exports/read`, and `exports/release` MUST exist only on the authenticated control listener when the handoff gate is enabled. With the gate disabled, all five routes, handoff root/schema initialization, policy actions, and migration behavior MUST be absent. The execution listener MUST have none of these routes and MUST disclose no handoff ID, export token, broker root, or content path. Local UDS and authenticated remote HTTPS MUST share the same HTTP contract.

#### Scenario: Gate-disabled routes and storage

- **GIVEN** workspace handoff is disabled
- **WHEN** NixOS and Home Manager configurations evaluate and the broker starts
- **THEN** capture, import, `exports/prepare`, `exports/read`, and `exports/release` SHALL be absent
- **AND** no handoff root, schema, migration, policy action, or storage operation SHALL activate
- **AND** existing private-workspace behavior SHALL remain unchanged

#### Scenario: QA reset and fresh cycle

- **GIVEN** QA acceptance requests a destructive reset
- **WHEN** operators stop the QA gateway, both broker sockets, and broker service
- **THEN** they SHALL verify and quarantine the whole canonical `/var/lib/hermes-qa-sandbox` state directory, not edit a database or selected handoff tree
- **AND** SHALL recreate an empty mode-`0700` state directory before restarting QA
- **AND** SHALL verify fresh capture, private import, and export prepare/read/release before deleting quarantine

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
