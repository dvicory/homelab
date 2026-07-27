## MODIFIED Requirements

### Requirement: Automatic frozen output capture

A successful broker-backed completion MUST invoke the required completion-finalizer and capture exactly `/workspace/output`; an empty output directory is valid and paths outside it remain scratch. Every model-facing Kanban `artifacts` entry MUST be an explicitly selected normalized relative path naming one regular file under the trusted task workspace; broker-backed selections MUST additionally lie below `output/`. Before the broker call, Kanban MUST validate only path syntax, rejecting absolute, traversal, URI, drive, host, empty-segment, or symlink-escape forms without inspecting contents or filesystem nodes. Thus broker regular-file and symlink checks occur when `exports/prepare` validates the frozen handoff. Native scratch/dir/worktree flows MUST copy each selected relative file into native attachment storage before `done`. Summary/result prose or fields MUST NOT discover or add paths. The broker capture request MUST contain exactly trusted `finalizationId`, `environmentKey`, `taskId`, and `runId`; schemas MUST reject extras and it MUST NOT accept a model-selected root, host path, handoff ID, workspace ID, lease ID, or artifact list.

The broker capture operation MUST preflight the live output while the activation and writer lease remain active, then consume the exact activation, revoke the writer, close the VM, drain VFS callbacks, copy and validate a detached destination temporary, fsync, and atomically install one immutable handoff. Kanban MUST remain in its existing `running` state until a ready handoff is returned. Before transitioning to `done`, the required broker-backed finalizer MUST call `exports/prepare` for every selected artifact against that frozen handoff; any prepare failure is a completion-operation failure and MUST keep the task non-done. Native scratch/dir/worktree attachment-copy failure is likewise completion-critical. Later `exports/read` or platform-delivery failures are retryable after `done`. This change MUST NOT introduce Kanban `finalizing` or `publication_failed` task statuses; those labels are workspace-operation recovery states only.

#### Scenario: Producer completion captures the fixed subtree

- **GIVEN** a claimed broker-backed Kanban worker has produced files under `/workspace/output`
- **WHEN** Kanban accepts completion metadata and invokes the required finalizer
- **THEN** the broker SHALL preflight and capture exactly `/workspace/output` in one capture call
- **AND** the model SHALL NOT need a storage identifier, workspace tool, output-root field, or republication action
- **AND** Kanban SHALL remain `running` until the broker returns a ready handoff
- **AND** before `done`, the finalizer SHALL call `exports/prepare` for every selected artifact against the frozen handoff
- **AND** a prepare failure SHALL keep the task non-done as a completion-operation failure, while later read or platform-delivery failure remains retryable after `done`

#### Scenario: Prose-only task has empty output

- **GIVEN** a broker-backed task completes successfully with an empty `/workspace/output`
- **WHEN** the required finalizer runs
- **THEN** the broker SHALL consume the run and record a finalized empty handoff
- **AND** no other workspace path SHALL be captured

#### Scenario: Completion metadata is rejected before capture or native attachment

- **GIVEN** `artifacts` or a path-valued completion field is absolute, host-derived, traversal-based, a URI/drive path, empty-segment, or a symlink escape
- **WHEN** Kanban validates completion
- **THEN** it MUST reject before invoking the broker capture route, fencing, or native attachment copy
- **AND** the task SHALL remain `running` with its active run and writer lease
- **AND** no artifact selector SHALL be inferred from summary/result prose or fields

#### Scenario: Subscription does not infer files

- **GIVEN** a completion subscription names recipients or channels but no explicit artifact files
- **WHEN** Hermes schedules delivery
- **THEN** it SHALL route only those recipients/channels
- **AND** it MUST NOT infer one file, the output directory, or the whole handoff

### Requirement: Completion response loss and operation replay

The broker MUST journal a finalization before filesystem mutation and bind the finalization ID to the trusted source activation, task, run, environment, policy decision, and fixed output source. An identical replay MUST return or resume the same operation. After the activation has been consumed, replay MUST use the journal and MUST NOT revalidate the active source. A changed bound fact MUST be an idempotency conflict. A deliberately fresh producer attempt MUST use both a fresh run ID and a fresh finalization ID.

#### Scenario: Response is lost before fencing

- **GIVEN** Kanban invoked capture but no broker staging or activation-consumption commit occurred
- **WHEN** recovery retries the same finalization ID
- **THEN** the broker SHALL use the still-active source to preflight and fence at most once
- **AND** Kanban SHALL remain `running` until a ready handoff exists
- **AND** no empty substitute or producer redispatch SHALL occur

#### Scenario: Response is lost after fencing

- **GIVEN** the broker journal committed activation consumption and the writer lease was revoked but the response was lost
- **WHEN** recovery repeats the identical finalization ID and request
- **THEN** the broker SHALL resume or return the journaled operation without checking the source activation as active
- **AND** a ready result SHALL identify the same opaque handoff
- **AND** it MUST NOT create a second handoff or redispatch the producer

#### Scenario: Transient post-fence retry

- **GIVEN** fencing completed but copy, detached validation, fsync, or rename temporarily failed
- **WHEN** trusted recovery retries the same finalization operation
- **THEN** the broker SHALL retain the operation's staging/failure/quarantine accounting and retry it
- **AND** Kanban SHALL remain non-done under existing lifecycle handling
- **AND** no summary prose or empty handoff SHALL make the task `done`

#### Scenario: Fresh run uses a fresh finalization

- **GIVEN** trusted lifecycle deliberately starts another producer attempt after a failed operation
- **WHEN** it activates a fresh run
- **THEN** it MUST allocate a fresh finalization ID
- **AND** prior run IDs and closed generations MUST remain fenced
- **AND** the new operation MUST not overwrite or replay the prior operation

### Requirement: Two-phase output structure validation

The broker MUST validate the fixed output subtree before and after fencing. Live preflight MUST run while the task remains `running` and MUST reject malformed names, traversal, NUL, invalid UTF-8, normalization collisions, symlinks, disallowed hardlinks, sockets, devices, FIFOs, unreadable entries, source filesystem crossings, and excess of exactly these configured limits: `maxLogicalBytes`, `maxEntries`, `maxFileBytes`, and `maxPathBytes`. Sparse files count by logical size. Preflight failure MUST leave the active run and writer lease in place. No invalid entry may be silently deleted, skipped, or rewritten.

After fencing, the broker MUST copy only directories and regular files to a broker-owned destination temporary without following symlinks, preserving hardlinks, or carrying host ownership/ACL/xattr authority. It MUST validate node kinds, readability, independent destination identity, normalized modes, and the same four limits before fsync and atomic rename. Copying bytes is required storage behavior, not content scanning. The broker MUST NOT silently delete, skip, rewrite, or publish a partial tree.

#### Scenario: Preflight rejects an unsafe tree

- **GIVEN** the live output contains traversal, invalid naming, a symlink, a disallowed hardlink, a special file, an unreadable entry, a filesystem crossing, or one of the four limit violations
- **WHEN** broker preflight runs before activation consumption
- **THEN** the capture MUST fail while Kanban remains `running`
- **AND** the active run, lease, and VM SHALL remain recoverable
- **AND** no entry may be silently deleted or omitted

#### Scenario: Structurally bad fenced output

- **GIVEN** preflight passed but the output changed during fencing or the detached copy exposes an unsafe node, unreadable file, independent-identity mismatch, or limit excess
- **WHEN** detached validation runs
- **THEN** no finalized handoff MAY be published
- **AND** the broker operation SHALL become `publication_failed`, `quarantined`, or `failed` with journaled temporary/failure detail
- **AND** Kanban SHALL not transition to `done`

#### Scenario: Safe tree is frozen atomically

- **GIVEN** the detached output tree contains only allowed directories and regular files within all four limits
- **WHEN** validation and fsync complete
- **THEN** the broker SHALL atomically install the destination temporary as one immutable handoff
- **AND** later writes or retries against the task workspace SHALL NOT change the frozen handoff

### Requirement: Direct-child source authority and private copy

Before every import request, including replay after a response loss, Kanban MUST verify that its recorded source is the task that created the destination as a direct child, that the direct-parent link still exists, that source and destination are on the same board and tenant, that the source is `done` with one ready handoff, and that both assignee policies permit private copy. Kanban MUST perform these checks again after any durable preparation intent and immediately before calling the broker. The model MUST NOT select an arbitrary source, parent, dependency, task, handoff, workspace, lease, or host path.

Only after those checks pass may trusted dispatch call `/v1/control/workspace-handoffs/import`. The request JSON MUST contain exactly `preparationId`, `sourceHandoffId`, `sourceTaskId`, `destinationTaskId`, `destinationRunId`, and `destinationEnvironmentKey`; schemas MUST reject every extra field. The broker MUST derive source provenance from the immutable `sourceHandoffId` record, including producing task/run/environment and ready frozen storage, reject a `sourceTaskId` mismatch, and derive destination provenance from trusted destination task/run/environment records. It MUST bind those derived IDs to one preparation ID, copy only the ready frozen output into a new private writable destination workspace, and issue an independent lease. The broker MUST NOT treat a client assertion as proof of board, tenant, direct-parent, or source task state.

#### Scenario: Authorized direct child

- **GIVEN** a same-board, same-tenant parent created a directly linked child and now has one ready handoff
- **WHEN** Kanban revalidates the relation and trusted dispatch prepares the child
- **THEN** it SHALL create durable preparation intent and request one private broker copy
- **AND** the broker SHALL bind the derived source and destination IDs to that preparation
- **AND** child mutation SHALL NOT change the parent frozen handoff or producer workspace

#### Scenario: Link or task state mutates before import

- **GIVEN** preparation intent was recorded but the direct-parent link was removed, board or tenant changed, the source is no longer `done`, the handoff is no longer ready, or either policy changed
- **WHEN** Kanban performs the import-time validation
- **THEN** it MUST reject before calling the broker
- **AND** the destination SHALL remain blocked or non-runnable
- **AND** no empty substitute, live-parent read, or partial destination workspace SHALL be created

#### Scenario: Source is not ready

- **GIVEN** the source is not `done` under existing Kanban task state, has a failed workspace operation, is blocked or rejected, or has no ready handoff
- **WHEN** dispatch evaluates the destination
- **THEN** the destination SHALL remain non-runnable or explicitly dependency-blocked
- **AND** no empty workspace SHALL masquerade as the requested input

#### Scenario: Private child mutation and automatic child capture

- **GIVEN** a child starts from a private copy of its parent's frozen output
- **WHEN** it edits or deletes files and later completes
- **THEN** only its own workspace SHALL change before fencing
- **AND** the parent frozen handoff and producer workspace SHALL remain unchanged
- **AND** its completion SHALL automatically capture its changed `/workspace/output`

#### Scenario: Blocked or rejected reviewer

- **GIVEN** a reviewer/child cannot receive a ready source or is marked blocked or rejected
- **WHEN** Kanban records that reviewer outcome
- **THEN** the reviewer SHALL remain blocked or rejected without a live parent read or empty substitute
- **AND** the parent draft SHALL not be auto-promoted, marked done, captured, or delivered
- **AND** reviewer state SHALL not establish source authority for another task

### Requirement: Retry, block, and reclaim fence the old run

A retry of one Kanban task MUST reuse retained mutable workspace only after trusted dispatch activates a fresh globally unique run ID and supersedes the prior activation. Completion, block, timeout, and operator reclaim MUST consume or supersede the active broker activation before VM closure. A late request from the old run MUST fail even when the lease or task identity is retained. Reclaim MUST use existing upstream operator lifecycle and MUST NOT capture, import, export, or deliver workspace data.

#### Scenario: Completed run attempts recreation

- **GIVEN** completion consumed an activation and revoked its writer lease while retaining workspace state
- **WHEN** the old worker calls ensure, execution, or file APIs using its prior run identity
- **THEN** the broker MUST reject the request
- **AND** stable task identity or lease knowledge MUST NOT recreate the VM or mutate retained output

#### Scenario: Block consumes before close

- **GIVEN** an active run is blocked or times out while its VM remains live
- **WHEN** trusted lifecycle handles the block
- **THEN** it SHALL consume or supersede the activation before closing the VM
- **AND** the old run SHALL be stale before any close race can recreate it

#### Scenario: Operator reclaim consumes before close

- **GIVEN** an operator reclaims an active run through the existing Kanban reclaim operation
- **WHEN** upstream lifecycle terminates and requeues the run
- **THEN** broker activation consumption or supersession SHALL precede VM close
- **AND** reclaim MUST NOT capture, import, export, deliver, or expose a handoff
- **AND** a later attempt MUST obtain a fresh activation and run ID

#### Scenario: Imported child retries

- **GIVEN** a child already owns its private copied workspace
- **WHEN** that child retries
- **THEN** it SHALL reuse its own retained workspace under a newer run
- **AND** SHALL NOT re-copy over child changes
- **AND** its eventual completion SHALL capture its own output automatically

### Requirement: Human delivery uses expiring export tokens

For broker-backed tasks, `artifacts` MUST remain the explicit selection of normalized relative regular-file paths under the trusted task workspace and below `output/`; Kanban MUST validate only their syntax before capture, while `exports/prepare` verifies each selected frozen path is a regular file. Hermes MUST own recipient/channel retry. Subscriptions MAY carry recipients and channels, but MUST NOT carry files or infer output. Summary/result prose or fields MUST NOT discover or add path selections. Broker delivery MUST use exactly `exports/prepare`, `exports/read`, and `exports/release` on the control listener. Before Kanban records `done`, the required finalizer MUST prepare every selected path against the ready frozen handoff and a prepare failure MUST remain a completion-operation failure. The broker MUST authorize a ready handoff, verify each path is a regular file in frozen storage, issue an expiring opaque token for one path, stream only that frozen file, and release/expire the token; it MUST NOT expose a host path or use a shared spool.

`exports/prepare` MUST accept exactly `deliveryId`, `handoffId`, and `relativePath`; identical active `(deliveryId, handoffId, relativePath)` tuples MUST return the same token/name/size/expiry after response loss, changed tuples MUST conflict, and expired or released delivery IDs MUST fail. A fresh delivery MUST use a new `deliveryId`. `exports/read` MUST accept only the token, and `exports/release` MUST accept only the token.

The same HTTP contract and schemas MUST operate through a local authenticated UDS client and authenticated remote HTTPS. Remote HTTPS MUST authenticate a principal with a mandatory bearer credential supplied by a trusted deployer secret, use standard CA and hostname verification, disable redirects, and terminate TLS at the remote service. Current QA UDS mode does not configure remote HTTPS or a bearer credential. Transport choice MUST NOT change authorization, route names, token ownership, file selection, or idempotency. Hermes MUST release the token after success, recipient failure, or interrupted read and MAY retry later read/platform delivery without invalidating a ready handoff or completed Kanban task.

#### Scenario: Explicit delivery

- **GIVEN** a completed task has a ready handoff and an explicit relative file below `output/`
- **WHEN** Hermes calls `exports/prepare`, `exports/read`, and `exports/release`
- **THEN** the broker SHALL stream exactly that file from frozen storage
- **AND** it MUST NOT widen delivery to the directory or infer additional files

#### Scenario: Export token replay and expiry

- **GIVEN** an export token was released or its expiry time passed
- **WHEN** a client replays `exports/read` or `exports/release`
- **THEN** the broker MUST reject the read and MUST NOT reopen the frozen file
- **AND** the ready handoff and Kanban task SHALL remain valid

#### Scenario: Interrupted export read

- **GIVEN** a recipient disconnects while `exports/read` is streaming
- **WHEN** Hermes records the delivery attempt
- **THEN** it SHALL release the token in cleanup and retry through its recipient-delivery operation
- **AND** no shared spool, live VM read, or partial handoff SHALL be treated as completion

#### Scenario: Recipient outage

- **GIVEN** the handoff is ready but a recipient or channel is unavailable
- **WHEN** Hermes delivery fails
- **THEN** the task SHALL remain `done`
- **AND** the handoff SHALL remain immutable and valid
- **AND** Hermes SHALL retain a retryable delivery operation independent of broker capture

### Requirement: Gated transport and recovery behavior

Capture, import, `exports/prepare`, `exports/read`, and `exports/release` MUST exist only on the authenticated broker control listener when the QA handoff gate is enabled. With the gate disabled, all five routes, handoff storage initialization, and handoff policy actions MUST be absent. The execution listener MUST have none of these routes and MUST disclose no handoff ID, export token, broker root, or content path.

#### Scenario: Gate-disabled routes and storage

- **GIVEN** workspace handoff is disabled
- **WHEN** the broker and Hermes configurations evaluate
- **THEN** capture, import, `exports/prepare`, `exports/read`, and `exports/release` SHALL be absent
- **AND** no handoff root, schema, migration, or storage operation SHALL activate
- **AND** existing private-workspace behavior SHALL remain unchanged

#### Scenario: Local UDS and remote HTTPS parity

- **GIVEN** a trusted client uses either the local broker UDS or remote HTTPS
- **WHEN** it invokes any handoff route
- **THEN** request schemas, response schemas, authorization, token expiry, release behavior, and prepare idempotency SHALL be identical
- **AND** remote HTTPS SHALL require the trusted-deployer bearer credential with standard CA/hostname verification and no redirects, while current QA UDS mode SHALL configure neither remote HTTPS nor that credential
- **AND** no shared filesystem spool or alternate path protocol SHALL be required

#### Scenario: Broker outage

- **GIVEN** a child requires a creating parent's ready handoff or a worker requires a broker workspace
- **WHEN** the broker or its sockets are unavailable
- **THEN** dispatch MUST fail closed or remain retryable before worker execution
- **AND** it MUST NOT fall back to host scratch, local execution, Docker, Podman, a live parent, or an empty handoff
- **AND** broker recovery SHALL not require a Hermes process restart

#### Scenario: Fresh QA reset and rollback

- **GIVEN** QA acceptance requires reset or rollback
- **WHEN** operators stop QA gateway/sockets/service and move the whole canonical QA state directory to quarantine
- **THEN** they SHALL recreate an empty mode-`0700` state directory and verify fresh capture, import, and export prepare/read/release before deleting quarantine
- **AND** disabling the gate SHALL leave all five routes and storage absent
- **AND** production Hermes, production state, rootless Podman storage, and gateway credentials MUST remain untouched
