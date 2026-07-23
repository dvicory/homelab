## Why

The QA Gondolin broker currently derives one anonymous directory from an environment key, cannot list or deliberately retain/delete work, and lets VM lifecycle stand in for workspace lifecycle. Hermes Kanban still hands workers host paths, so its task workspace contract does not compose with the secure terminal boundary.

## What Changes

- Add a persisted workspace catalogue with opaque workspace IDs, explicit owner authority, lifecycle state, retention metadata, and at-most-one writable lease.
- Separate disposable Gondolin runtime identity from durable workspace identity; VM recreation retains the selected workspace while switching workspaces recreates the VM.
- Add broker control operations to create, acquire, describe, list, release, close, and delete private workspaces without accepting arbitrary caller-selected host paths.
- Extend the trusted Hermes sandbox-authority binding so every secure-terminal environment carries a broker-issued workspace ID and lease.
- Make QA Kanban task dispatch acquire a private broker workspace keyed by trusted task identity, inject only opaque workspace/lease IDs plus guest path `/workspace`, and reuse it for retries.
- Close the live VM when a task reaches a terminal state while retaining the task-private workspace and lease for retry; explicit release remains an operator or future handoff action.
- Report explicit retained-workspace and ephemeral-root state when a VM generation changes.
- Keep parent/child handoff, project-source preparation, generic publication, and credential adapters outside this first increment.

## Capabilities

### New Capabilities

- `sandbox-workspace-lifecycle`: Durable workspace identity, registry, leases, retention, deletion, and VM attachment.
- `kanban-sandbox-workspace`: Trusted Kanban acquisition and reuse of task-bound secure-terminal workspaces.

### Modified Capabilities

- `task-sandbox-authority`: Authority binding gains an optional broker-issued workspace identity and fails closed on conflicting rebinding.

## Impact

- `pkgs/by-name/gondolin-broker-effect`: workspace registry/service module, control protocol, environment mount resolution, lifecycle reconciliation, and focused tests.
- `pkgs/by-name/hermes-agent-patched`: sandbox-access plugin and Kanban patches for trusted workspace acquisition and worker environment injection.
- `modules/den/aspects/workloads/hermes/secure-terminal`: broker state/configuration and QA policy wiring.
- `modules/den/users/hermes-runners.nix`: QA-only selection; production remains unchanged.
- `hvn-hyp1`: QA broker and Hermes gateway activation only.
- No nix-darwin or standalone home-manager behavior changes.

## Non-goals

- Git/Mercurial source preparation, optimized copy-on-write providers, canonical checkout import, push, pull request creation, or credential substitution.
- A general Agent X identity/space implementation or household ACL system.
- General model-facing workspace administration or publication tools.
- Shared writable workspaces, concurrent collaboration, parent/child forks or handoff, network-file direct write, skills projection, PTY/background support, or production cutover.
- Preserving or importing existing anonymous broker workspace directories.

## Technical Assumptions

- The first provider is broker-owned private storage under the existing sandbox account; no arbitrary source path enters the API.
- The existing Effect broker SQLite database remains the initial persistence boundary, while the workspace code has a narrow provider/service interface that can become a separate process later.
- The current Hermes profile/task authority key remains the trusted ownership input for QA. It is not represented as a general user principal.
- Kanban task identity is the trusted acquisition input. The broker, not the Kanban row, persists the workspace and lease; Hermes passes those opaque references only to the matching worker process.
- One writable lease per workspace is sufficient for task retries. New and child tasks receive distinct workspaces; cross-task dataflow requires a separate immutable handoff design.
- New files are added to Git before Nix evaluation so flake sources include them.
- The schema adds only `workspaces` (one row per durable private workspace) and `workspace_leases` (one row per acquisition, updated on release). `environments` is rebuilt without `workspace_path` and instead references `workspace_id` plus `workspace_lease_id`. File contents, directory manifests, Git state, command output, and VM history remain outside SQLite.
- Migration is a clean QA cutover: existing environment rows and anonymous workspace directories are removed after containment checks; they are not copied, adopted, quarantined, or interpreted as workspace records. Existing authority requests and grants remain only when their immutable policy/authority validation still succeeds.

## Refactoring

Environment creation will stop deriving its writable host directory directly from `environmentKey`. A dedicated workspace service resolves the binding and returns the validated mount path. This refactor is required to make workspace retention, switching, deletion, and lease fencing independent of VM generation; it is not general repository abstraction work.

## Rollback

The feature remains gated by the QA Gondolin configuration. Rollback reactivates the previous QA release and recreates its ephemeral environment state; it does not attempt to translate new durable workspaces back into anonymous `workspace_path` rows. Production and the Podman fallback are not modified. Before rollback, any wanted QA workspace files must be exported explicitly; otherwise the new tables and broker-owned workspace directories may be removed.