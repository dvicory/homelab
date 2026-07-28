## ADDED Requirements

### Requirement: Task-run workspace activation

Stable task identity and an active workspace lease MUST NOT be sufficient to create, reuse, execute in, or access files in a handoff-enabled environment. Before worker spawn, trusted dispatch MUST activate a globally unique run against the frozen board/task/run/lane/policy binding, workspace, and lease. Every ensure, execution, and file request MUST receive that identity from trusted backend state; model-facing schemas MUST NOT accept or override it.

Completion, block, timeout, and reclaim MUST consume or supersede the active activation before VM closure. A trusted retry MUST use a fresh run ID, and older runs and generations MUST remain stale.

#### Scenario: Completed run attempts recreation

- **GIVEN** completion consumed a task-run activation and revoked its writer lease
- **WHEN** the old worker invokes ensure, execution, or file APIs
- **THEN** the broker MUST reject the request
- **AND** task identity or lease knowledge MUST NOT recreate the VM or mutate retained output

#### Scenario: Block or reclaim races VM close

- **GIVEN** a live run is blocked, timed out, or reclaimed while its VM remains open
- **WHEN** trusted lifecycle handles the outcome
- **THEN** it MUST consume or supersede the activation before requesting VM close
- **AND** reclaim MUST NOT capture or deliver workspace data

### Requirement: Fenced automatic output capture

The required completion finalizer MUST call `POST /v1/control/workspace-handoffs/capture` with exactly `finalizationId`, trusted `environmentKey`, `taskId`, `runId`, and `selectedArtifacts`; schemas MUST reject extras. The broker MUST capture exactly `/workspace/output` and MUST NOT accept another root, host path, workspace/lease ID, handoff ID, or model-selected infrastructure field.

The broker MUST authorize the frozen worker binding, preflight the live tree and every selected artifact while the run remains active, consume the exact activation, revoke the writer, close and drain the VM, copy into broker-owned temporary storage, validate the detached tree, fsync, and atomically install one immutable handoff. The ready response MUST contain the opaque handoff ID, structural counts, and the verified selected-artifact manifest. An empty output tree with an empty selection is valid.

#### Scenario: Capture selected durable output

- **GIVEN** an authorized active task run with valid `/workspace/output` and selected regular files
- **WHEN** the required completion finalizer invokes capture
- **THEN** the broker SHALL preflight before consuming the activation
- **AND** SHALL return one immutable ready handoff containing the exact selected-artifact manifest
- **AND** later producer writes MUST NOT change it

#### Scenario: Empty output

- **GIVEN** an authorized run has empty `/workspace/output` and no selected artifacts
- **WHEN** capture runs
- **THEN** the broker SHALL finalize an empty frozen tree
- **AND** MUST NOT capture another workspace path

#### Scenario: Selected artifact is absent or unsafe

- **GIVEN** a selected path is absent, names a directory, leaves `output/`, or resolves through a link
- **WHEN** live preflight validates the request
- **THEN** capture MUST fail before activation consumption
- **AND** the run and writer lease SHALL remain available for correction

### Requirement: Two-phase structural validation

The broker MUST validate the fixed output subtree before and after the writer fence. It MUST reject malformed names, absolute or traversal segments, NUL, invalid UTF-8, normalization collisions, symlinks, disallowed hardlinks, sockets, devices, FIFOs, unreadable entries, filesystem crossings, and excess of exactly `maxLogicalBytes`, `maxEntries`, `maxFileBytes`, and `maxPathBytes`. Sparse files MUST count by logical size. It MUST never silently delete, skip, rewrite, or hide an invalid entry.

After fencing, copying MUST follow no links, cross no source filesystem boundary, preserve no hardlinks, and carry no source ownership, timestamps, ACLs, or xattrs. Detached validation MUST recheck allowed node kinds, independent destination identity, readability, normalized modes, all four limits, and the selected regular files before fsync and atomic rename. No content scanning is permitted.

#### Scenario: Unsafe live tree

- **GIVEN** output contains an unsafe node, unreadable entry, filesystem crossing, malformed path, or four-limit excess
- **WHEN** live preflight encounters it
- **THEN** capture MUST fail without following or exposing the target
- **AND** the activation and writer lease SHALL remain active

#### Scenario: Structurally bad fenced output

- **GIVEN** preflight passed but detached copy or validation finds an unsafe change or limit violation
- **WHEN** post-fence validation runs
- **THEN** no ready handoff MAY be published
- **AND** the journal SHALL retain failure or quarantine accounting without exposing a partial tree

### Requirement: Idempotent handoff capture recovery

The broker MUST journal a finalization before filesystem mutation and bind its ID to the exact activation, board/task/run/lane, optional Project/source generation, environment, workspace/lease, policy digest, fixed output source, ordered selected-artifact set, and operation kind. Identical replay MUST return or resume the same handoff. Changed bound facts MUST conflict. After activation consumption, replay MUST use the journal rather than requiring an active source.

#### Scenario: Response is lost before fencing

- **GIVEN** no staging or activation-consumption commit occurred
- **WHEN** the client retries the identical finalization
- **THEN** the broker MAY preflight and fence the still-active source once
- **AND** MUST NOT create an empty or model-attested substitute

#### Scenario: Response is lost after fencing

- **GIVEN** the operation consumed the activation but its response was lost
- **WHEN** the client retries the identical finalization
- **THEN** the broker SHALL resume or return the journaled operation without active-source validation
- **AND** MUST NOT create another handoff or redispatch producer work

#### Scenario: Finalization facts change

- **GIVEN** a finalization ID is bound to one source and selected-artifact set
- **WHEN** a caller reuses it with any changed bound fact
- **THEN** the broker MUST reject an idempotency conflict
- **AND** MUST NOT mutate the existing operation or handoff

### Requirement: Selected artifact reads over local UDS

The authenticated control listener MUST expose `POST /v1/control/workspace-handoffs/artifacts/read` only over the protected local UDS. It MUST accept exactly hidden `handoffId` and normalized `relativePath`; schemas MUST reject extras. The broker MUST require a ready handoff, require the exact path in its selected-artifact manifest, verify the frozen node remains one regular file with the recorded size, and stream only that file. It MUST NOT read the live workspace, infer files, widen selection, or create a shared spool.

#### Scenario: Read a selected artifact

- **GIVEN** a ready handoff records `output/report.pdf` in its selected-artifact manifest
- **WHEN** the trusted gateway reads that exact handoff and path over the control UDS
- **THEN** the broker SHALL stream exactly the frozen regular file
- **AND** SHALL disclose no broker root or host content path

#### Scenario: Read an unselected file

- **GIVEN** a ready handoff contains a regular file not listed in its selected-artifact manifest
- **WHEN** the gateway requests that path
- **THEN** the broker MUST deny the read
- **AND** MUST NOT widen authorization to the whole handoff

#### Scenario: Interrupted read

- **GIVEN** a local selected-artifact stream is interrupted
- **WHEN** Hermes retries materialization
- **THEN** it MAY repeat the same handoff/path read
- **AND** the ready handoff MUST remain immutable and valid

### Requirement: Local gate and recovery boundary

Activation, capture, and selected-artifact read routes MUST exist only on the authenticated local control listener when `workspaceHandoffEnabled` is true. Disabled startup MUST create no handoff schema, storage root, or policy actions. The execution listener MUST expose no handoff-management routes or metadata.

#### Scenario: Feature disabled

- **GIVEN** workspace handoff is disabled
- **WHEN** broker and Hermes configuration evaluate
- **THEN** activation, capture, and `artifacts/read` routes and storage SHALL be absent
- **AND** ordinary workspace behavior SHALL remain unchanged

#### Scenario: Execution listener attempts handoff access

- **GIVEN** a request reaches the execution listener
- **WHEN** it attempts activation, capture, selected-artifact read, listing, or description
- **THEN** the route MUST be absent or denied
- **AND** no handoff ID, manifest, broker root, or content path SHALL be disclosed

#### Scenario: Broker outage

- **GIVEN** capture or human artifact materialization requires the broker
- **WHEN** the broker or local UDS is unavailable
- **THEN** the operation MUST fail closed or remain retryable
- **AND** MUST NOT fall back to a live workspace, host path, local execution, Docker, Podman, or an empty substitute
