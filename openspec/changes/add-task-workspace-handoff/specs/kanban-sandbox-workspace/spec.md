## MODIFIED Requirements

### Requirement: Automatic frozen output capture

A successful broker-backed completion MUST invoke the required finalizer and capture exactly `/workspace/output`. Every model-facing `artifacts` entry MUST be an explicitly selected normalized relative path naming one regular file under the trusted task workspace and below `output/`. Kanban MUST perform syntax-only validation before the broker call and MUST NOT infer paths from summary/result prose or subscriptions.

The capture request MUST contain exactly `finalizationId`, trusted `environmentKey`, `taskId`, `runId`, and `selectedArtifacts`. The broker MUST validate the live tree and selections, fence the exact run, close and drain the VM, copy and validate detached storage, and return one immutable ready handoff with the selected-artifact manifest. Kanban MUST remain `running` until that response exists. Native scratch/dir/worktree completion MUST continue to materialize selected files into native attachment storage before `done`.

#### Scenario: Broker-backed completion

- **GIVEN** a claimed broker-backed worker produced valid output and selected relative artifacts
- **WHEN** Kanban invokes the required finalizer
- **THEN** the broker SHALL capture exactly `/workspace/output` and validate the selected files in one operation
- **AND** Kanban SHALL remain `running` until one ready handoff and selected-artifact manifest exist

#### Scenario: Prose-only completion

- **GIVEN** a broker-backed task completes with empty output and no selected artifacts
- **WHEN** the finalizer runs
- **THEN** the broker SHALL create an empty immutable handoff
- **AND** no other workspace path SHALL be captured

#### Scenario: Completion path is invalid

- **GIVEN** an artifact path is absolute, traversal-based, host-derived, malformed, outside `output/`, or a symlink escape
- **WHEN** Kanban validates completion
- **THEN** it MUST reject before invoking capture
- **AND** the task SHALL remain `running` without inferring a replacement from prose

### Requirement: Completion replay preserves one finalization

Kanban and the broker MUST bind one finalization ID to the exact frozen worker/run facts and ordered selected-artifact set. Identical replay MUST resume or return the same operation. A fresh producer run MUST receive a fresh finalization ID, and changed bound facts MUST conflict.

#### Scenario: Capture response is lost after fencing

- **GIVEN** the broker consumed the activation but Kanban did not receive the response
- **WHEN** recovery repeats the identical finalization request
- **THEN** the broker SHALL resolve the journal without requiring the source activation to be active
- **AND** MUST NOT create another handoff or redispatch the producer

#### Scenario: Fresh run follows failed finalization

- **GIVEN** trusted lifecycle deliberately starts another producer attempt
- **WHEN** the new run is activated
- **THEN** it MUST receive a fresh finalization ID
- **AND** prior runs, generations, and finalizations MUST remain fenced

### Requirement: Two-phase output structure validation

The broker MUST validate the fixed output subtree and every selected artifact before and after fencing. It MUST enforce exactly `maxLogicalBytes`, `maxEntries`, `maxFileBytes`, and `maxPathBytes`; reject malformed names, traversal, invalid UTF-8, normalization collisions, symlinks, disallowed hardlinks, special files, unreadable entries, filesystem crossings, and limit excess; and never silently delete, skip, or rewrite an entry. Detached copying MUST preserve no mutable file identity or host metadata and MUST publish no partial tree.

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

### Requirement: Retry, block, timeout, and reclaim fence the old run

A retry MUST activate a fresh globally unique run against the retained workspace and frozen worker binding. Completion, block, timeout, and reclaim MUST consume or supersede the active broker activation before VM closure. Late old-run operations MUST fail. Reclaim MUST NOT capture or deliver workspace data.

#### Scenario: Old run attempts recreation

- **GIVEN** completion, block, timeout, or reclaim consumed an activation
- **WHEN** that run invokes an execution or file operation
- **THEN** the broker MUST reject it
- **AND** task identity or lease knowledge MUST NOT recreate the VM

#### Scenario: Reclaim precedes close

- **GIVEN** an operator reclaims an active task
- **WHEN** lifecycle terminates and requeues it
- **THEN** activation consumption or supersession SHALL precede VM close
- **AND** a later attempt MUST obtain a fresh run activation

### Requirement: Human delivery uses frozen selected artifacts

For broker-backed tasks, Hermes MUST read only paths in the ready handoff's selected-artifact manifest through the protected local control UDS. The read request MUST contain exactly hidden `handoffId` and normalized `relativePath`. Hermes MUST materialize the returned bytes through upstream native attachment storage before invoking a platform adapter. Subscriptions MAY identify recipients and channels but MUST NOT identify or infer files.

Materialization and platform upload MUST be durable recipient/file delivery stages. Failure MUST leave that recipient/file outstanding and MUST NOT advance the completion-event subscriber cursor. Retry MUST target only outstanding deliveries. A successful or ambiguously timed-out platform call MAY be delivered more than once when the platform has no idempotency key; the system MUST NOT claim exactly-once delivery.

#### Scenario: Selected artifact delivery

- **GIVEN** a completed task has a ready handoff with a selected regular file
- **WHEN** Hermes materializes and uploads that file
- **THEN** it SHALL read the exact frozen file over the local UDS
- **AND** SHALL store it through native attachment storage before platform upload
- **AND** MUST NOT read the live workspace or infer additional files

#### Scenario: Local materialization fails

- **GIVEN** a selected artifact has not reached native attachment storage
- **WHEN** broker read or local storage fails
- **THEN** that recipient/file delivery MUST remain outstanding
- **AND** the subscriber cursor MUST NOT advance past the completion event

#### Scenario: One of several uploads fails

- **GIVEN** one completion event has multiple recipient/file deliveries
- **WHEN** some succeed and one fails
- **THEN** retry SHALL preserve successful acknowledgements and retry only outstanding deliveries
- **AND** the failed delivery MUST NOT be reported as delivered

#### Scenario: Platform timeout is ambiguous

- **GIVEN** a platform accepted a document but its response was lost
- **WHEN** Hermes retries the outstanding delivery
- **THEN** a duplicate MAY occur if the platform lacks an idempotency key
- **AND** the system MUST document at-least-once rather than claim exactly-once behavior

### Requirement: Gated local transport and outage behavior

Activation, capture, and `artifacts/read` MUST exist only on the authenticated broker control listener over the protected local UDS when the handoff gate is enabled. With the gate disabled, those routes, handoff storage initialization, and handoff policy actions MUST be absent. The execution listener MUST expose none of them.

#### Scenario: Gate-disabled routes and storage

- **GIVEN** workspace handoff is disabled
- **WHEN** broker and Hermes configuration evaluate
- **THEN** activation, capture, `artifacts/read`, handoff schema, and storage SHALL be absent
- **AND** ordinary workspace behavior SHALL remain unchanged

#### Scenario: Broker outage

- **GIVEN** a worker requires capture or a notifier requires a frozen selected artifact
- **WHEN** the broker or local UDS is unavailable
- **THEN** completion or delivery MUST fail closed or remain retryable
- **AND** MUST NOT fall back to host scratch, local execution, Docker, Podman, a live workspace, or an empty handoff
