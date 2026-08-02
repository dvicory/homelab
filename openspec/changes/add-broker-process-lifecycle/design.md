## Context

The broker already owns Gondolin VMs and synchronous execution. `VmHandle.exec` returns the command output stream and exact result, while `Executor.execute` adds authorization, limits, HTTP streaming, and a scoped finalizer that hard-closes the leased environment when the foreground stream is interrupted.

Hermes' generic non-local background fallback bypasses that ownership model. It launches a shell wrapper, writes PID/output/exit sentinels under guest `/tmp`, and reconstructs state with later executions. `/workspace` is broker-backed but guest `/tmp` is generation-local, so a durable side effect can survive while the exit sentinel disappears. The observed QA result—correct output file plus `exit_code=-1`, `completion_reason=lost`—is the expected failure mode.

Gondolin cannot restore a running process across VM or broker restart. The useful contract is therefore broker-lifetime background execution, not a durable process database.

## Goals / Non-Goals

**Goals:**

- Reuse foreground authorization, admission, VM execution, output decoding, deadline, and termination behavior.
- Keep each background execution alive independently of the initiating HTTP request.
- Return exact observed exit code/signal, bounded ordered output, and honest cancellation/loss state while the broker is alive.
- Bind process operations to the originating environment generation and authority.
- Remove Gondolin guest PID/log/exit files and repeated-shell polling.

**Non-Goals:**

- Process or terminal-result persistence across broker restart.
- VM/RAM restoration, PTY reattachment, or interactive stdin after spawn.
- A general durable job scheduler.
- Multiple output-storage backends or SQLite process journaling.
- Changes to local, Docker, Podman, SSH, Singularity, or other Hermes backends.

## Decisions

### Share command launch below the foreground stream

Extract the authorization/admission/launch portion of `Executor.execute` into one internal operation returning the authorized environment binding plus the live Gondolin process stream/result. Foreground execution retains its existing scoped HTTP stream and hard-close-on-interruption semantics. Background spawn calls the same operation but transfers ownership to the application-scoped process service before acknowledging the request.

Do not implement background execution by having the broker call its own public HTTP endpoint or by launching a detached guest shell.

### Application-scoped Effect process registry

Add a broker layer holding an in-memory map from cryptographically random opaque process ID to:

- environment key and generation;
- the immutable authority/binding digest needed for revalidation;
- supervised execution fiber;
- bounded stdout/stderr ring buffer with monotonic cursor;
- running, exited, cancelled, or lost state;
- observed exit code/signal and timestamps.

The process fiber drains Gondolin output and awaits `proc.result`. It outlives the spawn request but remains supervised by the broker application scope. Natural exit and cancellation race through one atomic terminal transition. Completed entries remain for a bounded TTL and count against bounded per-binding/global registry ceilings until removed.

No SQLite schema or restart reconciliation is added. Broker shutdown closes its VMs and fibers. After restart, old opaque process IDs are unknown and Hermes reports backend loss without a fabricated numeric exit code.

### Minimal API

Use three authenticated execution-listener operations:

- `POST /v1/processes/spawn`: existing trusted execution facts plus command; returns process ID and generation after ownership is installed.
- `POST /v1/processes/poll`: process ID plus output cursor; returns bounded ordered output, next cursor, truncation facts, and current/terminal state.
- `POST /v1/processes/cancel`: process ID; interrupts/terminates the owned execution and returns the winning terminal state.

Poll combines status and output because Hermes consumes them together. Model-facing schemas expose only the existing background/process concepts; trusted Gondolin environment state supplies environment and task-run authority.

### Fencing and closure

Every poll/cancel revalidates that the current trusted environment binding matches the process environment key, generation, and authority digest. A foreign or stale binding receives the same denial without process-data disclosure.

The initial policy admits exactly one background process per environment. Gondolin 0.12.0 accepts an `AbortSignal`, but abort only rejects and deletes the host exec session; it does not send a guest process-termination request. Cancellation therefore hard-closes the exact owning environment generation. The single-process ceiling prevents collateral background cancellation. Task completion, block, timeout, reclaim, branch copy, lease release, and workspace deletion call the same close/drain hook before output freeze or storage mutation. No process survives into a replacement generation.

### Bounded output

Use an in-memory byte-bounded tail buffer. Each chunk retains stdout/stderr identity and monotonic cursor. When the limit is exceeded, evict oldest chunks and report the first available cursor/truncated byte count. Poll responses also have a maximum byte limit. Output truncation never changes the real terminal result.

### Hermes cutover

Add `spawn_process`, `poll_process`, and `cancel_process` methods to the Gondolin broker client and expose a Gondolin process handle to `ProcessRegistry`. `spawn_via_env` selects it only when the environment advertises durable-for-broker-lifetime process support. Existing guest-wrapper behavior remains untouched for other backends.

Delete Gondolin use of `hermes_bg_*.pid`, `.log`, `.exit`, and `.exit.tmp`; delete delayed sentinel polling and the mocked regression that encoded it. An unknown process after broker restart becomes `completion_reason=lost` with no exit code, not `-1`.

## Risks / Trade-offs

- **Broker restart loses status.** Explicitly accepted: the VM and process are also lost. Hermes reports loss rather than inventing an exit result.
- **Application-scope leak.** Registry ceilings, process deadlines, terminal TTL, and broker-scope finalization bound memory and fibers.
- **Cancellation closes the environment.** Gondolin 0.12.0 has no targeted guest process termination: its abort listener only rejects and removes the host exec session. The exact owning generation is hard-closed, and the one-background-process ceiling avoids collateral background cancellation.
- **Foreground behavior regresses during refactor.** Preserve its current HTTP events, timeout, output ceiling, and ensuring finalizer with parity tests.
- **Task completion races output mutation.** Close/cancel and drain attached processes before handoff preflight and freeze.

## Migration Plan

1. Add shared launch primitive and foreground parity coverage.
2. Add the application-scoped process registry and three routes.
3. Add the Hermes Gondolin client/handle and remove its Gondolin guest-file path.
4. Wire bounded process policy through the secure-terminal module.
5. Deploy QA from clean state and exercise zero/nonzero exit, bounded output, cancellation, gateway disconnect, stale generation, completion drain, and broker-restart loss.
6. Roll back broker, Hermes image, and policy together; never use a runtime guest-file fallback.

