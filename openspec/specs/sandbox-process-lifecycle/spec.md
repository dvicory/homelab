# sandbox-process-lifecycle Specification

## Purpose
Define broker-owned, broker-lifetime asynchronous execution for Gondolin so status, bounded output, cancellation, and exit results do not depend on model-writable guest files or guest-local PIDs.
## Requirements
### Requirement: Broker-owned process identity and state

The broker MUST issue a cryptographically opaque process ID for every asynchronous command and bind it to the environment key, VM generation, trusted authority binding, command, and effective CWD. State MUST distinguish `running`, `exited`, `cancelled`, and `lost`. An observed terminal result MUST retain its exact exit code and signal for the configured in-memory terminal TTL.

Hermes and model-facing callers MUST NOT supply a guest PID, generation, authority binding, or terminal result. Guest files, guest PIDs, workspace content, and model-provided output MUST NOT be lifecycle authority.

#### Scenario: Asynchronous command exits nonzero

- **WHEN** an authorized background command exits with code 7 while the broker remains alive
- **THEN** the broker SHALL retain `exited` and exit code 7
- **AND** a later authorized poll within the terminal TTL SHALL return that result without executing a guest probe

#### Scenario: Caller invents terminal state

- **WHEN** a caller supplies a PID, exit code, generation, or authority override
- **THEN** trusted code SHALL reject or discard it
- **AND** the broker SHALL use only its owned process handle and binding

### Requirement: Background execution is application scoped

A successful spawn response MUST mean that the broker application scope owns and supervises the Gondolin execution independently of the spawn request scope. Gateway disconnection after acknowledgment MUST NOT cancel the process or discard its result. Broker shutdown or owning VM loss MAY terminate the process and discard its in-memory record; Hermes MUST represent a subsequent unknown process as lost without fabricating an exit code.

#### Scenario: Gateway disconnects after spawn

- **WHEN** the spawning HTTP request has completed and the gateway disconnects
- **THEN** the broker SHALL continue supervising the process
- **AND** a later authorized poll SHALL observe its output and terminal result

#### Scenario: Broker restarts

- **WHEN** Hermes polls a process ID issued by a prior broker instance
- **THEN** Hermes SHALL report backend/process loss
- **AND** SHALL NOT infer completion from guest files or return `exit_code=-1`

### Requirement: Bounded ordered polling

The broker MUST retain a byte-bounded in-memory tail of stdout and stderr with stream identity and monotonic cursors. Poll MUST return state, bounded output after the supplied cursor, a successor cursor, and explicit truncation facts. Per-process output, poll response, concurrent-process, and retained-terminal ceilings MUST come from trusted policy and MUST NOT be increased by model input.

#### Scenario: Poll resumes output

- **GIVEN** a caller consumed through cursor N
- **WHEN** it polls from cursor N
- **THEN** the broker SHALL return only retained events after N and a monotonic successor cursor

#### Scenario: Output exceeds retention

- **WHEN** output exceeds the retained-byte ceiling
- **THEN** the broker SHALL evict according to its declared tail policy and report truncation
- **AND** SHALL preserve the exact observed terminal result

### Requirement: Authenticated cancellation and generation fencing

Poll and cancellation MUST revalidate the current trusted binding against the process environment key, generation, and authority digest. Cancellation MUST target the broker-owned execution or, when targeted Gondolin termination is unavailable, hard-close only the owning environment generation. Natural exit and cancellation MUST race through one atomic terminal transition. Repeated cancellation of a retained terminal process MUST be idempotent.

#### Scenario: Matching caller cancels a process

- **WHEN** the owner cancels a running process
- **THEN** the broker SHALL terminate the process or its exact environment generation
- **AND** SHALL publish the winning exited or cancelled state

#### Scenario: Foreign or stale caller probes a process

- **WHEN** another authority binding or replacement generation presents the process ID
- **THEN** the broker SHALL deny poll and cancellation without disclosing process output

### Requirement: Workspace mutation drains processes

Environment close, generation replacement, task completion, block, timeout, reclaim, branch copy, lease release, and workspace deletion MUST cancel and drain every attached background process before freezing, copying, releasing, or deleting storage that it could mutate. A process MUST NOT transfer to a replacement generation.

#### Scenario: Completion races a background writer

- **WHEN** completion begins while an attached process can write `/workspace/output`
- **THEN** completion SHALL cancel and drain that process within the trusted bound or fail
- **AND** SHALL not freeze output while mutation remains possible

### Requirement: Gondolin has no guest-file process fallback

The Gondolin Hermes backend MUST implement background spawn, poll, and cancellation only through the broker process service. It MUST NOT create or poll `/tmp/hermes_bg_*`, use workspace files as sentinels, probe guest PIDs through later executions, fabricate numeric exit results, or fall back to local, Docker, Podman, SSH, or another backend. Other Hermes backends retain their existing behavior.

#### Scenario: Process service is unavailable

- **WHEN** a Gondolin background request cannot reach or authorize the broker process service
- **THEN** it SHALL fail closed
- **AND** no detached guest-wrapper or alternate-backend command SHALL start

