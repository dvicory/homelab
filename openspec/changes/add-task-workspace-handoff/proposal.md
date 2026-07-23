## Why

The QA Gondolin backend gives each Hermes Kanban task a durable private workspace, but one task cannot pass filesystem results to a child. The smallest useful collaboration increment is an immutable handoff: a producer publishes selected files when it completes, and one directly linked consumer starts from a private copy.

## What Changes

- Publish one immutable, bounded workspace revision from a task's selected relative paths after its VM is fenced and closed.
- Add broker task-run activation so stable task identity and a retained workspace lease cannot recreate a VM after completion; retry requires trusted dispatch to activate a newer run.
- Make publication a recoverable completion saga. Kanban enters `finalizing`, the broker publishes idempotently, and only then does the task become `done`.
- Let a producer create a child with `inherit_parent_workspace_output: true`. The caller's current task becomes the sole workspace source; trusted dispatch later resolves its revision and creates one new private writable child workspace. The model cannot name another source task.
- Extend existing Kanban create/completion requests only. Add no model-facing workspace-management tool, and accept no workspace, lease, revision, or host path as model authority.
- Gate the vertical slice to the `hvn-hyp1` QA Gondolin profile. Production Hermes and Podman remain unchanged.

## Capabilities

### New Capabilities

- `task-workspace-revisions`: Fenced publication, canonical manifest verification, idempotent private fork, and task-run activation fencing.
- `kanban-workspace-handoff`: Truthful completion publication and one-source parent-to-child handoff through existing Kanban operations.

### Modified Capabilities

None. `add-sandbox-workspace-service` remains the prerequisite private-workspace and broker-authority change until it is verified and archived.

## Impact

- `pkgs/by-name/gondolin-broker-effect`: task-run activation, revision, manifest, publication, private-import, and recovery state plus control routes and tests.
- `pkgs/by-name/hermes-agent-patched`: generic Kanban finalization/input metadata, required completion-finalizer support, dispatcher preparation, and the repository-owned workspace-service integration.
- `modules/den/aspects/workloads/hermes/secure-terminal/default.nix`: QA-only revision root, limits, policy actions, and feature wiring.
- `modules/den/users/hermes-runners.nix`: explicit QA selection only if the existing secure-terminal setting cannot carry the subfeature.
- `hvn-hyp1`: QA-only migration and activation. nix-darwin remains package/test evaluation; production and Podman state do not change.

## Deferred Follow-ups

- Dependency/sibling imports, multiple input revisions, labels, destination remapping, merge/conflict policies, and aggregation.
- Read-only reviewer mounts and separate reviewer scratch space.
- Revision grants, revocation, retention, deletion, deduplication, and long-term artifact storage.
- New cancellation states or broader replacement of Kanban's existing best-effort non-completion lifecycle hooks.
- Git/Mercurial providers, credentials, pull requests, and promotion into canonical project state.

## Non-goals

- Shared mutable project directories, live co-editing, or multi-writer leases.
- Model-selectable storage identifiers or host paths.
- Cross-board or cross-tenant handoff, public artifacts, executable import hooks, or production activation.

## Technical Assumptions

- `add-sandbox-workspace-service` has passed QA and provides broker-owned paths, one active writer lease, trusted backend-derived task identity, and fail-closed execution.
- The gateway/plugin/backend process and the mode-restricted control/execution Unix sockets are trusted. The model cannot set the task/run identity attached by the backend. Gateway-account compromise remains outside this increment's boundary.
- Before worker spawn, trusted dispatch registers a broker activation bound to task, Kanban run, workspace, lease, policy digest, and monotonic epoch. Every ensure, execution, and file request is checked against that active binding. Completion consumes it before VM closure; only a newer trusted run can reactivate the retained workspace.
- Revision IDs are random and publication-specific. A versioned canonical SHA-256 manifest digest verifies content but is retained in broker/Kanban provenance rather than ordinary model context.
- The initial store uses bounded full copies in broker-owned directories. It accepts directories and regular files only and rejects links, special files, traversal, mount crossings, unstable metadata, and configured resource-limit excess.
- Revisions are QA data retained until explicit QA reset in this increment. No deletion or retention API is exposed.

## Refactoring

First extract the broker's repeated SQLite connection/migration/transaction setup from workspace, environment registry, and access-grant services into one shared database service so lease, task-run activation, environment, and revision state can share real transactions. Keep storage logic in the broker and generic lifecycle/request plumbing in Hermes. Do not extend `sandbox-access` or add a provider abstraction.

## Rollback

The feature remains off outside `hvn-hyp1` QA. Rollback stops QA Hermes and broker units, restores the prior generation, and removes disposable revision rows/content only after containment checks. Existing mutable private workspaces remain governed by the prerequisite change; production and Podman state are untouched.
