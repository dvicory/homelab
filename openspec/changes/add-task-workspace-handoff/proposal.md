## Why

QA Gondolin gives each Hermes Kanban task a durable private workspace, but completion has no stable, trusted boundary for transferring output to a directly linked child. This change makes the fixed guest subtree `/workspace/output` the automatic handoff source while keeping human delivery explicit and task state owned by Kanban.

## What Changes

- A successful broker-backed completion automatically captures exactly `/workspace/output`. An empty directory is valid for prose-only work; every other workspace path remains scratch.
- Kanban requires every model-facing `artifacts` entry to be an explicitly selected normalized relative regular-file path under the trusted task workspace; broker-backed entries additionally lie below `output/`. Before invoking the broker, Kanban validates only path syntax and rejects absolute, traversal, URI/drive/host, empty-segment, or symlink-escape forms without inspecting contents or filesystem nodes. Summary/result prose or fields cannot discover paths. Native scratch/dir/worktree flows copy each selected relative file into native attachment storage before `done`; broker-backed completion uses one capture call containing exactly `finalizationId`, trusted `environmentKey`, `taskId`, and `runId`, with schemas rejecting extras. The broker preflights the live output while the activation is active, then consumes the activation, revokes the writer lease, closes the VM, drains callbacks, copies to broker-owned temporary storage, validates the detached tree, fsyncs it, and atomically installs one immutable handoff.
- Kanban remains in its existing `running` state until a ready handoff is returned. Before `done`, the broker-backed finalizer calls `exports/prepare` for every selected artifact against the frozen handoff; prepare failure is a completion-operation failure, while later read/platform-delivery failure remains retryable after `done`. Native attachment-copy failure is also completion-critical. This change does not introduce Kanban `finalizing` or `publication_failed` task states. A preflight failure leaves the run active. A post-fence failure is journaled and remains non-done/retryable without publishing a partial tree.
- Replaying an identical finalization ID uses its journaled operation after activation consumption and returns or resumes the original handoff without rechecking the active source. A genuinely fresh attempt activates a fresh run ID and uses a fresh finalization ID; it never reopens an old run.
- Structural validation rejects traversal, malformed or colliding names, symlinks, disallowed hardlinks, special files, unreadable entries, and excess of the four wired limits: `maxLogicalBytes`, `maxEntries`, `maxFileBytes`, and `maxPathBytes`. The broker copies bytes but performs no content scanning and never silently deletes an entry.
- A directly linked child may receive only the creating parent's finalized output after Kanban revalidates the direct-child, board, tenant, source-state, handoff, and policy facts on every import. The broker request contains exactly `preparationId`, `sourceHandoffId`, `sourceTaskId`, `destinationTaskId`, `destinationRunId`, and `destinationEnvironmentKey`; it derives source handoff provenance from immutable broker records, rejects mismatches, and creates a private writable copy with an independent lease.
- Block and reclaim paths consume or supersede the active run before closing its VM. A stale run or retained lease cannot recreate a generation or mutate retained output.
- Human delivery uses the exact broker export protocol: `exports/prepare` accepts exactly `deliveryId`, `handoffId`, and `relativePath`, returns an expiring opaque export token for one explicit frozen regular file, and is idempotent for an identical active tuple; changed tuples conflict, expired/released delivery IDs fail, and a fresh delivery uses a new ID. `exports/read` accepts only the token and `exports/release` accepts only the token. Hermes owns recipient/channel retry and releases tokens after success, failure, or interrupted reads; the broker does not infer files or maintain a shared spool. Remote HTTPS requires a mandatory bearer credential from a trusted deployer secret, standard CA/hostname verification, no redirects, and remote-service TLS termination; current QA UDS mode configures no remote HTTPS or bearer credential.
- Gate the vertical slice to the `hvn-hyp1` QA Gondolin profile. When disabled, capture, import, and all three export routes are absent. Production Hermes, local workers, Podman, and nix-darwin remain unchanged.

## Capabilities

### New Capabilities

- `task-workspace-handoffs`: broker-owned task/run fencing, automatic capture, immutable handoff storage, private child import, and expiring export-token operations.

### Modified Capabilities

- `kanban-sandbox-workspace`: existing Kanban workspace acquisition, completion, direct-child validation, retry/block/reclaim lifecycle, delivery, and outage behavior are updated to use the handoff boundary.

## Impact

- `pkgs/by-name/gondolin-broker-effect`: task-run activation fencing, handoff/import records, operation journal, structural validation, frozen storage, and the five gated handoff routes (`capture`, `import`, `exports/prepare`, `exports/read`, `exports/release`).
- `pkgs/by-name/hermes-agent-patched`: generic Kanban completion/finalization and import persistence, pre-broker completion validation, trusted dispatcher facts, export-token delivery retry, and the repository workspace-service bridge.
- `modules/den/aspects/workloads/hermes/secure-terminal/default.nix`: QA-only handoff gate, the four structural limits, policy actions, transport/authentication, and service wiring.
- `hvn-hyp1`: QA-only enablement, reset, rollback, and acceptance evidence. Production and Podman state do not change.

## Deferred Follow-ups

- Dependency or sibling inputs, multiple sources, labels, destination remapping, merge/conflict policies, aggregation, reviewer mounts, and reviewer scratch space.
- Handoff grants, retention or deletion APIs, deduplication, long-term project storage, and any shared mutable workspace.
- Content scanning, semantic validation, secret/malware inspection, and content-derived authority.
- New model-facing cancel, publication, import, export, or workspace-management tools; existing upstream retry/reclaim mechanics remain the lifecycle surface.
- Git/Mercurial providers, credentials, pull requests, and promotion into canonical project state.

## Non-goals

- Whole-workspace capture, arbitrary output-root selection, model-selected storage identifiers, host paths, live co-editing, multi-writer leases, cross-board or cross-tenant handoff, public artifacts, executable import hooks, or production activation.

## Technical Assumptions

- `add-sandbox-workspace-service` has passed QA, is verified, and is archived before this change is implemented.
- Trusted dispatch attaches task/run identity and policy facts; model-facing schemas cannot set workspace, lease, handoff, source, destination, or host-path authority. Ordinary/non-Gondolin workers retain their existing per-session CWD and workspace behavior.
- Before worker spawn, trusted dispatch activates a globally unique Kanban run against its task, workspace, lease, and policy digest. Every execution/file request is checked against that binding. Completion consumes it before output bytes are read. Block and reclaim consume or supersede it before VM closure.
- The broker writes its operation journal before filesystem mutation and keeps source provenance, staging, failure, and ready state. A replay with identical immutable facts is idempotent; a changed fact conflicts. Handoff IDs and operation IDs are random opaque identifiers, never content-derived authorities and never model inputs.
- Structural limits are exactly `maxLogicalBytes`, `maxEntries`, `maxFileBytes`, and `maxPathBytes`. Symlinks, disallowed hardlinks, special files, traversal, unreadable entries, and limit excess fail closed. No content scanning occurs.
- Kanban is authoritative for direct-child, board, tenant, source-task-state, and policy validation on every import. The broker receives only the exact trusted import fields, derives source provenance from the handoff record, and binds them to a preparation ID.
- Export clients use the same authenticated HTTP request/response contract through local UDS or remote HTTPS. Hermes owns recipient retry; the broker owns token preparation, streaming read, expiry, and release. Remote HTTPS authentication uses the trusted-deployer bearer credential with standard CA/hostname verification and redirects disabled; the current QA UDS mode does not configure it.

## Refactoring

Extract the broker's repeated SQLite connection, migration, and transaction setup from workspace, environment registry, and access-grant services into one shared database service. Keep handoff storage and filesystem operations in the broker, generic lifecycle and delivery retry in Hermes, and Kanban graph/state validation in Kanban. Do not add a provider abstraction or extend `sandbox-access`.

## Rollback and QA Reset

The feature remains off outside `hvn-hyp1`. Rollback disables `secureTerminal.workspaceHandoff.enable` (or restores the preceding NixOS and QA Home Manager generations), stops the `hermes-qa` user service, and restarts the QA broker sockets and service. Disabled configuration installs no handoff storage and exposes none of the five handoff routes. Production Hermes, rootless Podman storage, and gateway credentials are not stopped, moved, or deleted.

A destructive QA reset stops the QA gateway, both QA broker sockets, and the QA broker service; verifies that the candidate is exactly beneath `/var/lib/hermes-qa-sandbox` and is neither `/var/lib/hermes-prod-sandbox` nor a Podman path; then moves the whole canonical QA broker state directory to an operator-named same-filesystem quarantine. It recreates the empty state directory with mode `0700`, starts only QA services, and verifies fresh capture, private import, and prepare/read/release export before deleting the quarantine. It never edits the database or removes a handoff tree independently. Acceptance records a fresh reset cycle, disabled-route behavior, rollback, and unchanged production/Podman state.
