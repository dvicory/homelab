# hermes-conversation-workspace-identity Specification

## Purpose
TBD - created by archiving change preserve-hermes-workspace-identity. Update Purpose after archive.
## Requirements
### Requirement: Stable private conversation workspace identity

A broker-backed Hermes conversation MUST derive workspace ownership from persisted compression-only session lineage. The trusted workspace owner MUST be held in task-local process context and MUST NOT be exported to child processes, guests, model-visible arguments, or logs. Gateway routing keys, platform/chat/thread identifiers, approval routing identities, titles, and process-local caches MUST NOT determine workspace ownership. Only the opaque derived environment key MAY cross the broker API.

#### Scenario: Resume through another gateway route

- **GIVEN** a conversation has written a file in its broker workspace
- **WHEN** an authorized `/resume` opens the same persisted conversation through another gateway route
- **THEN** its next terminal and file calls SHALL derive the same canonical environment key
- **AND** the original file SHALL remain visible
- **AND** the raw workspace owner SHALL not appear in subprocess or guest environment state

#### Scenario: Compression rotates the live transcript segment

- **GIVEN** a conversation workspace exists and Hermes creates a compression continuation
- **WHEN** the continuation executes an environment-backed tool
- **THEN** Hermes SHALL resolve the compression-only lineage root
- **AND** the broker SHALL reattach the existing workspace and lease binding

#### Scenario: Persisted lineage is unavailable

- **GIVEN** Hermes cannot read persisted session lineage
- **WHEN** it must derive workspace ownership
- **THEN** it SHALL isolate on the current durable transcript segment
- **AND** it MUST NOT fall back to a gateway key, stale process-global value, or another conversation

### Requirement: Explicit isolation boundaries

`/new`, unrelated conversations, delegated/subagent sessions, and tool sessions MUST receive distinct workspace ownership unless an existing trusted task handoff authorizes transfer. Generic `parent_session_id` traversal MUST NOT grant workspace access.

#### Scenario: New conversation starts on the same route

- **GIVEN** a route currently selects a conversation with a broker workspace
- **WHEN** `/new` creates another conversation on that route
- **THEN** the new conversation SHALL derive a different environment key and private workspace
- **AND** it SHALL not observe the prior conversation's files or processes

#### Scenario: Delegate carries a parent link

- **GIVEN** a delegated or tool session records the current conversation as its parent
- **WHEN** it resolves execution authority
- **THEN** it SHALL retain its exact task/run authority identity
- **AND** it SHALL not obtain the conversation workspace by walking that parent link

### Requirement: Private branch workspace inheritance

A successful `/branch` from a broker-backed conversation MUST initialize a distinct private writable workspace from a consistent copy of the parent workspace at the branch point. Parent and branch MUST NOT share a workspace ID, lease, fencing token, VM generation, or later mutations.

#### Scenario: Branch inherits parent files without sharing

- **GIVEN** the parent workspace contains files and may have a live VM
- **WHEN** Hermes prepares a branch
- **THEN** the broker SHALL close and drain the parent VM before copying
- **AND** it SHALL atomically install a complete private copy for the branch
- **AND** parent and branch SHALL each retain independent writable workspaces
- **AND** writes made after the branch point in either workspace SHALL not appear in the other

#### Scenario: Empty parent workspace branches

- **GIVEN** the parent has no workspace files or has never executed a tool
- **WHEN** Hermes prepares a branch
- **THEN** the broker SHALL create an empty private child workspace
- **AND** the parent and child SHALL still receive distinct ownership and leases

#### Scenario: Branch preparation is replayed

- **GIVEN** the broker completed branch preparation but Hermes lost the response
- **WHEN** Hermes retries the same operation ID with identical source and destination facts
- **THEN** the broker SHALL return the same destination workspace binding
- **AND** it SHALL not create another copy or lease
- **AND** changed source or destination facts SHALL fail as an idempotency conflict

#### Scenario: Branch preparation fails

- **GIVEN** the parent cannot be quiesced, copied, validated, or installed
- **WHEN** Hermes attempts `/branch`
- **THEN** Hermes SHALL not switch the active route to the branch
- **AND** it MUST NOT substitute an empty, shared, local, Docker, or Podman workspace
- **AND** any provisional branch session SHALL be deleted or remain non-selectable until preparation succeeds

