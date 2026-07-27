## ADDED Requirements

### Requirement: Task-run workspace activation

Stable task identity and an active workspace lease MUST NOT be sufficient to create, reuse, execute in, or access files in a handoff-enabled environment. Before worker spawn, trusted dispatch MUST activate a globally unique Kanban run ID against its task, workspace, lease, and active policy digest. The broker MUST issue an opaque activation ID. Every ensure, execution, and file request MUST use task/run identity attached by trusted backend state; model-facing schemas MUST NOT accept or override it.

Completion, block, timeout, and reclaim MUST consume or supersede the active activation before VM closure. Activating a trusted retry with a fresh run ID MUST supersede the older activation and close its generation before another generation is created. A prior run ID MUST NOT be reactivated.

#### Scenario: Completed run attempts recreation

- **GIVEN** completion consumed a task-run activation, revoked its writer lease, and closed its VM while retaining task workspace state
- **WHEN** the old worker calls ensure, execution, or file APIs using its prior run identity
- **THEN** the broker MUST reject the request
- **AND** stable task identity or lease knowledge MUST NOT recreate the VM or mutate retained output

#### Scenario: Block or reclaim races VM close

- **GIVEN** a live run is blocked, timed out, or reclaimed while its VM remains open
- **WHEN** trusted lifecycle handles the outcome
- **THEN** it MUST consume or supersede the activation before requesting VM close
- **AND** a late request from the old run MUST be stale before it can recreate a generation
- **AND** reclaim MUST NOT capture or publish workspace data

#### Scenario: Trusted retry

- **GIVEN** a retained task workspace has no active run after completion, block, timeout, reclaim, or failure
- **WHEN** trusted dispatch registers a fresh Kanban run ID against the current lease and policy
- **THEN** the broker SHALL permit that run to create a new VM generation
- **AND** all older runs and generations MUST remain stale

### Requirement: Fenced automatic output capture

The required completion-finalizer MUST capture exactly the guest subtree `/workspace/output` for an authorized active task run. Its request MUST contain exactly `finalizationId`, trusted `environmentKey`, `taskId`, and `runId`; schemas MUST reject extras. It MUST NOT accept a model-selected root, a host path, a workspace or lease identifier, an opaque handoff identifier, or an artifact list. Model-facing Kanban artifact entries MUST be explicitly selected normalized relative regular-file paths under the trusted task workspace; broker-backed selections additionally lie below `output/`. Kanban performs syntax-only path validation before this broker call and MUST reject absolute, traversal, or symlink-escape forms without inspecting file contents or filesystem nodes. Summary/result prose or fields MUST NOT discover paths.

The broker capture operation MUST authorize the task, resolve its active activation, preflight `/workspace/output` while the run and writer lease are still active, and only then transactionally consume the exact activation. It MUST revoke the writer lease, mark the generation closing, await VM exit and VFS callback drain, copy the output subtree into broker-owned destination-temporary storage, validate the detached tree, fsync, atomically install one frozen handoff, and assign a random opaque handoff ID. An empty output directory is valid. The frozen tree MUST be immutable from every workspace and guest path and MUST NOT share mutable file identity. Authority is the fenced source run and broker-owned finalized storage, not canonical content comparison; copying bytes performs no content scanning. Before Kanban records `done`, the required completion-finalizer MUST call `exports/prepare` for every syntactically selected artifact against this frozen handoff; any prepare failure is a completion-operation failure, while later read or platform-delivery failure remains retryable after `done`.

#### Scenario: Capture selected durable output

- **GIVEN** an authorized active task run with a structurally valid `/workspace/output`
- **WHEN** the required completion lifecycle invokes capture
- **THEN** the broker SHALL preflight before consuming the activation
- **AND** SHALL fence and revoke the writer before reading output bytes
- **AND** SHALL return one verified ready handoff with an opaque ID
- **AND** later writes in a retried producer workspace MUST NOT change it

#### Scenario: Empty output

- **GIVEN** an authorized active task run has an empty `/workspace/output`
- **WHEN** the required lifecycle captures the run
- **THEN** the broker SHALL finalize an empty frozen tree
- **AND** MUST NOT capture any path outside `/workspace/output`

#### Scenario: Preflight response is recoverable

- **GIVEN** live preflight rejects output before activation consumption
- **WHEN** capture returns the structural error
- **THEN** the activation and writer lease SHALL remain active
- **AND** Kanban SHALL keep the task in its existing `running` state
- **AND** a later attempt MAY correct the output under that active run

#### Scenario: Old request races capture

- **GIVEN** capture has consumed the source run activation and revoked its writer lease
- **WHEN** an execution or file request from that run arrives
- **THEN** it MUST be rejected
- **AND** no post-fence bytes MAY enter the finalized handoff

### Requirement: Two-phase structural validation

The broker MUST structurally validate the fixed output subtree before and after the writer fence. Live preflight MUST validate names, node kinds, link policy, readability, source filesystem identity, and exactly these configured limits: `maxLogicalBytes`, `maxEntries`, `maxFileBytes`, and `maxPathBytes`. It MUST reject absolute or host paths, empty segments, `.`, `..`, NUL, invalid UTF-8, normalization collisions, symlinks, disallowed hardlinks, sockets, devices, FIFOs, unreadable entries, and limit excess. Sparse files count by logical size. A preflight failure MUST leave the activation, writer lease, and VM recoverable. It MUST never silently delete, skip, rewrite, or hide an invalid entry.

After fencing, the broker MUST copy only allowed directories and regular files to same-filesystem broker-owned destination-temporary storage without following symlinks, crossing the source filesystem boundary, preserving hardlinks, or preserving source ownership, timestamps, ACLs, xattrs, or other host metadata. It MUST validate the detached temporary again, including node type, independent file identity, readability, normalized modes, and the four limits, before fsync and atomic rename. No partial tree may become ready. Structural inspection and byte-copy errors are the complete validation surface; no content scanning is permitted.

#### Scenario: Unsafe node or path

- **GIVEN** output contains traversal, invalid naming, a symlink, a disallowed hardlink, a special file, an unreadable entry, a filesystem crossing, or a four-limit excess
- **WHEN** preflight or detached validation encounters it
- **THEN** capture MUST fail without following or exposing the target
- **AND** the offending entry MUST remain accounted for in failure or quarantine state rather than being silently removed

#### Scenario: Structurally bad fenced output

- **GIVEN** preflight passed but the source changed during fencing or detached copy reveals an unsafe node, unreadable file, identity mismatch, or limit excess
- **WHEN** post-fence validation runs
- **THEN** no ready handoff MAY be published
- **AND** the operation SHALL retain `publication_failed`, `quarantined`, or `failed` state with temporary and failure accounting
- **AND** a retry MUST not expose a partial tree

#### Scenario: Safe tree is atomically frozen

- **GIVEN** the detached tree contains only allowed nodes and is within all four limits
- **WHEN** structural validation and fsync complete
- **THEN** the broker SHALL atomically install the destination temporary as ready handoff storage
- **AND** consumers and delivery SHALL read that frozen tree rather than the live task workspace

### Requirement: Idempotent handoff capture recovery

The broker MUST persist an operation journal before filesystem mutation. Each finalization ID MUST bind the trusted source activation/task/run/environment/workspace/lease facts, fixed `/workspace/output` source, policy decision, and capture operation kind. Repeating an identical request MUST return or resume the same opaque handoff. Once the activation has been consumed, replay MUST use the recorded operation and MUST NOT require the source activation to be active. Reusing the ID with any changed bound field MUST fail. Journal state MUST cover preflight, staged/fenced, copying, detached validation, ready, `publication_failed`, quarantine, and failure; restart recovery MUST reconcile each state without silently dropping a temporary tree or producing a second ready handoff.

#### Scenario: Response is lost before fencing

- **GIVEN** the client received no response and the broker has no staged or consumed operation
- **WHEN** recovery repeats the same finalization ID while the source activation remains active
- **THEN** the broker MAY preflight and fence that source once
- **AND** MUST NOT create an empty or model-attested substitute

#### Scenario: Finalized response is lost

- **GIVEN** the broker consumed the activation, fsynced and installed a ready handoff, but Kanban did not record the response
- **WHEN** recovery repeats the same finalization ID and request
- **THEN** the broker SHALL resolve the journal without active-source validation and return the same opaque handoff
- **AND** MUST NOT create another frozen tree or redispatch the producer

#### Scenario: Post-fence failure is retryable

- **GIVEN** activation consumption and writer revocation succeeded
- **WHEN** copy, detached validation, fsync, or atomic rename fails transiently
- **THEN** the operation SHALL retain journaled `publication_failed`, quarantine, or failure state
- **AND** trusted recovery SHALL retry the same operation without rechecking the active source
- **AND** a deliberate fresh producer retry MUST use a fresh run ID and fresh finalization ID
- **AND** no summary prose or empty substitute MAY make the Kanban task `done`

#### Scenario: Conflicting replay

- **GIVEN** a finalization ID is bound to one source activation, task/run, environment, policy, and fixed source
- **WHEN** a caller reuses it with a different bound value
- **THEN** the broker MUST reject it as an idempotency conflict
- **AND** MUST NOT mutate the existing handoff or journal

### Requirement: Authorized private child copy

The control listener MAY copy one ready handoff for one destination child/run only after Kanban has proved on every import attempt that the source task created that direct child, the direct parent link still exists, source and destination share board and tenant, the source is `done` with one ready handoff, and source/destination policies match. The import request JSON MUST contain exactly `preparationId`, `sourceHandoffId`, `sourceTaskId`, `destinationTaskId`, `destinationRunId`, and `destinationEnvironmentKey`; schemas MUST reject every extra field. It MUST NOT carry source-run, board, tenant, parent/link, source-state, policy, workspace, lease, or host-path assertions. The broker MUST derive source provenance from the immutable `sourceHandoffId` record, including its producing task/run/environment and ready frozen storage, and MUST reject a `sourceTaskId` mismatch; it MUST derive destination provenance from trusted destination task/run/environment records. The broker MUST bind the derived provenance and IDs to one preparation ID, verify ready handoff provenance, structurally validate the frozen source, copy it into a destination temporary, atomically install one new private writable workspace at `/workspace`, and issue an independent lease. Handoff IDs MUST NOT be accepted by execution routes or model-facing requests.

#### Scenario: Direct child copy

- **GIVEN** Kanban has freshly validated a completed parent, a direct child, the same board and tenant, and one ready handoff
- **WHEN** trusted dispatch prepares the destination with a new preparation ID
- **THEN** the broker SHALL copy only the frozen output into one private destination workspace
- **AND** destination writes MUST NOT change the source frozen handoff or producer workspace bytes

#### Scenario: Link or state changes before import

- **GIVEN** a preparation intent exists but the direct link, board, tenant, source `done` state, ready handoff, or policy changes
- **WHEN** Kanban revalidates immediately before import
- **THEN** Kanban MUST reject before calling the broker
- **AND** the child MUST remain blocked/non-runnable without an empty workspace or live-parent access

#### Scenario: Copy response is lost

- **GIVEN** the broker committed a destination workspace and lease but Kanban did not record its response
- **WHEN** recovery repeats the identical preparation ID after Kanban revalidates the relation
- **THEN** the broker SHALL return the same workspace and lease
- **AND** MUST NOT create a second writable copy

#### Scenario: Copy identity changes

- **GIVEN** a preparation ID is bound to one source, destination, derived relation, handoff, and policy
- **WHEN** it is reused with any different bound value
- **THEN** the broker MUST reject it as an idempotency conflict

#### Scenario: Source is blocked or rejected

- **GIVEN** the parent is not `done` under existing Kanban task state, has a failed workspace operation, is blocked, or is rejected
- **WHEN** Kanban or a child requests preparation
- **THEN** Kanban MUST refuse the import before worker spawn and before the broker call
- **AND** the child/reviewer MUST remain blocked or rejected without an empty workspace or live-parent access
- **AND** no parent draft may be auto-promoted or captured as a result

### Requirement: Human delivery export tokens

The control plane MUST expose exactly these handoff delivery operations: `POST /v1/control/workspace-handoffs/exports/prepare`, `POST /v1/control/workspace-handoffs/exports/read`, and `POST /v1/control/workspace-handoffs/exports/release`. `prepare` MUST accept exactly `deliveryId`, `handoffId`, and one normalized relative path; schemas MUST reject extras, and the broker MUST verify that the path is one regular file in the frozen handoff. It MUST return an expiring opaque `exportToken`, basename, size, and expiry. `read` MUST accept only the token and stream that one file from frozen storage. `release` MUST accept only the token and make it unavailable for later reads. Expired or released tokens MUST fail closed. The broker owns token authorization, expiry, streaming, and release; Hermes owns recipient/channel retry. No shared spool, live VM read, host path, or inferred file selection is allowed.

For `prepare`, the active idempotency tuple is `(deliveryId, handoffId, relativePath)`. A response loss followed by an identical request MUST return the same active token/name/size/expiry without creating another token. Reusing an active `deliveryId` with any changed tuple member MUST fail as an idempotency conflict without changing the existing token. An expired or released `deliveryId` MUST fail, even when the tuple is repeated; a fresh delivery MUST allocate a new `deliveryId`.

The same request/response and streaming HTTP contract MUST work through the local authenticated UDS client and authenticated remote HTTPS. Transport choice MUST NOT change route schemas or ownership.

#### Scenario: Explicit artifact delivery

- **GIVEN** a ready handoff and an explicit relative file below `output/`
- **WHEN** Hermes prepares, reads, and releases an export token
- **THEN** the broker SHALL stream exactly that file from the frozen handoff
- **AND** MUST NOT widen selection to the directory or infer additional files

#### Scenario: Token replay after release

- **GIVEN** Hermes released an export token
- **WHEN** a client replays `exports/read` or `exports/release`
- **THEN** the broker MUST reject the read and keep the token non-active
- **AND** the ready handoff SHALL remain immutable and valid

#### Scenario: Token expiry

- **GIVEN** an export token's expiry time has passed
- **WHEN** a client calls `exports/read`
- **THEN** the broker MUST transition the token to expired and reject the stream
- **AND** no file bytes SHALL be read from the live workspace

#### Scenario: Interrupted read

- **GIVEN** a recipient disconnects during `exports/read`
- **WHEN** Hermes handles the interrupted delivery
- **THEN** it SHALL call `exports/release` in cleanup and retain recipient retry state
- **AND** the broker MUST not create a shared spool or invalidate the ready handoff

#### Scenario: Recipient outage

- **GIVEN** a ready handoff but an unavailable recipient or channel
- **WHEN** Hermes delivery fails
- **THEN** the Kanban task SHALL remain `done`
- **AND** the handoff SHALL remain valid and immutable
- **AND** Hermes SHALL retain a retryable delivery operation

### Requirement: Broker gate and QA recovery

`pkgs/by-name/gondolin-broker-effect` MUST own task-run activation, writer revocation, handoff/import records, four-limit structural validation, frozen-tree copy, atomic rename, export-token operations, and recovery. Handoff capture/import/export routes MUST exist only on the authenticated control listener under explicit policy actions. The execution listener MUST not expose them. The handoff gate MUST control activation routes, schema initialization, roots, and all five handoff routes.

The local UDS and remote HTTPS clients MUST share one HTTP contract. Remote HTTPS MUST authenticate a principal with a mandatory bearer credential supplied by a trusted deployer secret, use standard CA and hostname verification, disable redirects, and terminate TLS at the remote service. Local calls MUST use the protected broker UDS; the current QA UDS mode does not configure remote HTTPS or a bearer credential. Ordinary workers, non-Gondolin workers, production Hermes, Podman, and nix-darwin behavior MUST remain unchanged. QA reset and rollback MUST quarantine/recreate only canonical QA state and MUST leave production/Podman untouched.

#### Scenario: Execution listener attempts handoff management

- **GIVEN** a request reaches the broker execution listener
- **WHEN** it attempts capture, import, export preparation, export read, export release, listing, or handoff description
- **THEN** the route MUST be absent or denied
- **AND** no handoff ID, export token, structural metadata, broker root, or content path SHALL be disclosed

#### Scenario: Feature disabled

- **GIVEN** workspace handoff is disabled
- **WHEN** NixOS and Home Manager configurations evaluate and the broker starts
- **THEN** capture, import, `exports/prepare`, `exports/read`, and `exports/release` SHALL be absent
- **AND** no handoff root, schema, migration behavior, policy action, or operation SHALL activate
- **AND** existing private-workspace behavior SHALL remain unchanged

#### Scenario: QA reset and rollback

- **GIVEN** QA acceptance requests a destructive reset or rollback
- **WHEN** operators stop the QA gateway, broker sockets, and broker service
- **THEN** they SHALL verify and quarantine the whole canonical `/var/lib/hermes-qa-sandbox` state directory, not a selected database or tree
- **AND** SHALL recreate an empty mode-`0700` state directory before restarting QA
- **AND** SHALL verify fresh capture, private import, and export prepare/read/release before quarantine deletion
- **AND** disabling the gate SHALL leave all five routes and storage absent
- **AND** production Hermes services, production state, rootless Podman storage, and gateway credentials MUST remain untouched
