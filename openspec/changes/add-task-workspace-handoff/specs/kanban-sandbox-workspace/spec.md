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

For broker-backed tasks, Hermes MUST read only paths in the ready handoff's selected-artifact manifest through the protected local control UDS. The read request MUST contain exactly hidden `handoffId` and normalized `relativePath`. Before transitioning the task to `done`, Hermes MUST idempotently materialize every selected file through upstream native task attachment storage, independent of recipient subscriptions. A completed task's selected files MUST therefore be available through ordinary task attachment inspection even when no platform recipient exists. Subscriptions MAY identify recipients and channels but MUST NOT identify or infer files.

Task/file materialization and recipient/attachment upload MUST be distinct durable stages. Materialization failure MUST keep the task in its existing `running` state and MUST remain retryable from the ready handoff without redispatching producer work. Upload failure MUST leave that recipient/attachment outstanding and MUST NOT advance its completion-event subscriber cursor. Retry MUST target only outstanding deliveries. A successful or ambiguously timed-out platform call MAY be delivered more than once when the platform has no idempotency key; the system MUST NOT claim exactly-once delivery.

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

- **GIVEN** one completed task has multiple recipient/attachment deliveries
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
