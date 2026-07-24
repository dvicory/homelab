## ADDED Requirements

### Requirement: One-source handoff through existing Kanban operations

Hermes MUST NOT add a model-facing workspace publication, import, list, switch, grant, release, or delete tool. Existing completion MAY accept `workspace_outputs`, a non-empty list of relative paths. Existing task creation MAY accept `inherit_parent_workspace_output: true`; trusted Kanban context MUST record the caller's current task as the sole workspace source and direct parent. The model MUST NOT name a source task. Neither request MUST accept workspace IDs, lease IDs, revision IDs, host paths, destination remapping, or multiple sources.

#### Scenario: Producer declares output

- **GIVEN** a claimed Kanban worker has produced workspace files
- **WHEN** it completes with valid `workspace_outputs`
- **THEN** Kanban SHALL persist the selected relative roots as finalization intent
- **AND** the model SHALL NOT need a storage identifier or workspace tool

#### Scenario: Child declares input

- **GIVEN** a Kanban worker creates a directly linked child
- **WHEN** it sets `inherit_parent_workspace_output: true`
- **THEN** Kanban SHALL record the caller's trusted current task as the child's logical workspace source
- **AND** SHALL NOT accept or expose a source revision ID in the model request

#### Scenario: Unsupported storage selection

- **GIVEN** a request supplies a workspace, lease, revision, host path, destination path, or second input source
- **WHEN** the Kanban schema validates it
- **THEN** the request MUST be rejected
- **AND** the value MUST NOT establish storage authority

#### Scenario: Non-worker requests inherited output

- **GIVEN** task creation has no trusted current Kanban task/run context
- **WHEN** it sets `inherit_parent_workspace_output: true`
- **THEN** the request MUST be rejected
- **AND** a caller-supplied parent ID MUST NOT substitute for trusted source context

### Requirement: Published completion is durable and truthful

A handoff-enabled Gondolin completion MUST consume the exact broker task/run activation and close its VM before becoming `done`. When `workspace_outputs` is present, Kanban MUST first enter durable `finalizing` state, invoke a required completion-finalizer, and record the verified broker revision result before `done`. Existing best-effort observers MUST NOT authorize publication. Model summary prose MUST NOT substitute for broker evidence. Completion without outputs MUST still fence the run but MUST NOT create a revision.

#### Scenario: Successful publication

- **GIVEN** a running claimed task completes with selected outputs
- **WHEN** the broker fences the run and returns a verified ready revision
- **THEN** Kanban SHALL record source run, selection, opaque revision reference, manifest digest, finalization ID, and timestamps
- **AND** only then SHALL the task transition to `done`

#### Scenario: Completion response hides storage metadata

- **GIVEN** publication succeeds and Kanban records broker provenance internally
- **WHEN** completion returns to the worker or later ordinary task context is rendered
- **THEN** revision IDs, manifest digests, workspace IDs, lease IDs, and host paths MUST be omitted
- **AND** an explicit operator audit surface MAY show non-capability provenance

#### Scenario: Broker unavailable

- **GIVEN** a task has durably entered `finalizing`
- **WHEN** required fencing or publication fails
- **THEN** the task MUST NOT be reported `done`
- **AND** the same immutable finalization intent SHALL remain recoverable
- **AND** no downstream task MAY receive model-attested or empty substitute files

#### Scenario: Worker exits after broker success

- **GIVEN** the broker committed a ready revision but Kanban did not record it
- **WHEN** dispatcher recovery claims the stale finalization
- **THEN** it SHALL repeat the same finalization ID and record the same broker result
- **AND** MUST NOT redispatch the producer body or create a second revision

#### Scenario: Completion has no selected output

- **GIVEN** a handoff-enabled Gondolin task completes without `workspace_outputs`
- **WHEN** the required completion fence succeeds
- **THEN** its run SHALL be consumed and VM closed
- **AND** existing completion result/summary behavior SHALL continue without a revision

### Requirement: Parent-issued source authorization

Before preparing a consumer, the dispatcher MUST verify its recorded workspace source is the trusted task that created it, the direct parent link still exists, source and destination are on the same board and tenant, the source is `done` with one broker-verified ready revision, and both assignee policies permit private import. The model MUST NOT select an arbitrary parent, dependency, task, or revision as workspace input.

#### Scenario: Authorized direct child

- **GIVEN** a same-board, same-tenant parent created a directly linked child with inherited output and now has a ready revision
- **WHEN** dispatcher preparation validates both profiles
- **THEN** it SHALL create durable preparation intent and request one private broker import
- **AND** SHALL record source/destination task and run provenance outside ordinary model context

#### Scenario: Source is not ready

- **GIVEN** the selected source is not `done` or has no ready revision
- **WHEN** dispatch evaluates the destination
- **THEN** the destination SHALL remain non-runnable or explicitly dependency-blocked
- **AND** no empty workspace SHALL masquerade as the requested input

#### Scenario: Source is unrelated or crosses boundary

- **GIVEN** the recorded source was not the creating worker, the direct parent link was removed, or board/tenant differs
- **WHEN** preparation evaluates the input
- **THEN** it MUST fail closed before worker spawn
- **AND** MUST NOT reveal arbitrary revision existence

### Requirement: Preparation precedes worker spawn

Kanban MUST persist a unique preparation ID and immutable source/destination intent before broker import. It MUST record the idempotent broker workspace/lease result before spawning the consumer. The consumer MUST receive one private writable workspace and independent lease at `/workspace`; it MUST NOT share producer or revision bytes.

#### Scenario: Preparation response is lost

- **GIVEN** the broker committed an import but Kanban did not record its response
- **WHEN** dispatcher recovery repeats the same preparation ID and intent
- **THEN** it SHALL record the same workspace/lease result before spawn
- **AND** MUST NOT create or dispatch against a second import

#### Scenario: Imported child mutates files

- **GIVEN** a child starts from a private import
- **WHEN** it edits or deletes files
- **THEN** only its own workspace SHALL change
- **AND** the producer workspace and immutable revision SHALL remain unchanged

### Requirement: Retry remains task-private

A retry of the same task MUST use its retained mutable workspace only after trusted dispatch activates a fresh globally unique Kanban run ID and supersedes the prior activation. It MUST NOT import its own published revision over current task state. A different task MUST always receive a separate private import.

#### Scenario: Producer retries after publication failure

- **GIVEN** a trusted transition returns a failed finalization to runnable state with retained bytes
- **WHEN** the producer is dispatched again
- **THEN** the broker SHALL register a newer run activation over that workspace
- **AND** prior runs and closed generations MUST remain fenced

#### Scenario: Imported child retries

- **GIVEN** a child already owns its imported private workspace
- **WHEN** that child retries
- **THEN** it SHALL reuse its own retained workspace under a newer run
- **AND** SHALL NOT re-import over child changes

### Requirement: Hermes integration remains generic and gated

`pkgs/by-name/hermes-agent-patched` MUST implement generic Kanban finalization/preparation persistence, a required completion-finalizer interface, and dispatcher replay without embedding filesystem logic in model tools. The repository-owned `workspace-service` plugin MUST activate task runs, invoke broker fence/publication/import control operations, and attach trusted task/run identity to backend calls. `modules/den/aspects/workloads/hermes/secure-terminal/default.nix` MUST enable this only for `hvn-hyp1` QA Gondolin. Non-Gondolin workers, Codex lanes, production Hermes, and nix-darwin behavior MUST remain unchanged.

#### Scenario: Non-Gondolin task

- **GIVEN** a worker profile does not enable Gondolin handoff
- **WHEN** it is dispatched and completed
- **THEN** existing task and workspace behavior SHALL remain unchanged
- **AND** no broker task-run activation, publication, or import route SHALL run

#### Scenario: Registered external Codex lane

- **GIVEN** QA Gondolin handoff is enabled and a task selects a registered external Codex lane
- **WHEN** the dispatcher prepares and spawns that task
- **THEN** the lane SHALL receive its existing host-visible task worktree, not the guest-only `/workspace`
- **AND** no broker task-run activation, publication, import, or workspace-preparation hook SHALL run
- **AND** the deployment MUST NOT claim Gondolin isolation for that Codex process

#### Scenario: Non-Kanban Gondolin conversation

- **GIVEN** a normal QA Gondolin conversation has no Kanban run
- **WHEN** it uses workspace-backed tools
- **THEN** existing conversation workspace behavior SHALL remain unchanged
- **AND** Kanban task-run activation, publication, and import records MUST NOT be created

#### Scenario: Input broker is unavailable

- **GIVEN** a Gondolin child requires its creating parent's revision
- **WHEN** trusted preparation cannot reach or validate the broker
- **THEN** dispatch MUST fail closed before worker execution
- **AND** MUST NOT fall back to upstream host scratch, local execution, Docker, or Podman
