## 1. Shared execution foundation

- [x] 1.1 Extract one internal authorized Gondolin command-launch operation from the foreground executor, preserving existing start/output/exit events, deadline, output ceiling, and hard-close-on-interrupted-stream behavior.
- [x] 1.2 Extend the runtime launch handle only with the ownership hooks needed by foreground and background consumers; document that Gondolin 0.12.0 abort does not terminate the guest command.
- [x] 1.3 Add foreground parity regressions before routing asynchronous work through the shared primitive.

## 2. Broker-lifetime process service

- [x] 2.1 Add process spawn, poll, and cancel domain schemas with opaque IDs, generation/binding fencing, combined bounded output/status polling, and no caller-selected authority fields.
- [x] 2.2 Implement an application-scoped Effect process registry with one running background process per environment, supervised fibers, atomic terminal transitions, bounded stdout/stderr tail cursors, terminal TTL, and global admission ceilings.
- [x] 2.3 Implement spawn by transferring the authorized live command into broker application ownership before acknowledgment; ensure gateway request cancellation after acknowledgment does not interrupt it.
- [x] 2.4 Implement poll and cancel authorization, output truncation reporting, exact exit code/signal publication, idempotent terminal cancellation, and hard-close of only the owning environment generation.
- [x] 2.5 Wire environment close, generation replacement, task completion, block, timeout, reclaim, branch preparation, lease release, and workspace deletion through bounded process cancel/drain before storage mutation.
- [x] 2.6 Expose exactly `/v1/processes/spawn`, `/v1/processes/poll`, and `/v1/processes/cancel` on the authenticated execution listener; add no process routes to the control listener or guest.

## 3. Hermes Gondolin cutover

- [x] 3.1 Add broker client methods and a Gondolin process handle that maps spawn, incremental poll, exact terminal result, cancellation, and unknown-after-restart to Hermes `ProcessRegistry` semantics.
- [x] 3.2 Select the broker process handle only for Gondolin; preserve every other backend's existing background implementation.
- [x] 3.3 Remove Gondolin creation and polling of `hermes_bg_*.pid`, `.log`, `.exit`, and `.exit.tmp`, delayed sentinel visibility retries, guest PID probes, and fabricated `exit_code=-1` results.
- [x] 3.4 Fail closed when the broker process service is unavailable or authority is stale; never substitute local, Docker, Podman, SSH, or detached guest execution.

## 4. Policy and verification

- [x] 4.1 Wire trusted command-duration, one-process-per-environment, retained-output, poll-response, terminal-TTL, and global registry ceilings through broker config and the secure-terminal Nix module.
- [x] 4.2 Cover zero and nonzero exits, stdout/stderr ordering, cursor resume, truncation, natural-exit/cancel races, terminal TTL, ceiling rejection, gateway disconnect, stale/foreign authority, environment hard-close, and broker-restart loss in focused broker tests.
- [x] 4.3 Replace mocked guest-sentinel Hermes tests with broker-process contract tests covering exact exit results, output polling, cancellation, unknown process loss without numeric exit code, and unchanged non-Gondolin backends.
- [x] 4.4 Run focused broker, patched-Hermes, secure-terminal Nix, and repository checks, then deploy QA from clean state.
- [x] 4.5 Repeat the live runtime-contract acceptance: a delayed background command writes its durable side effect, exits 7, and later process wait reports exactly exit 7 rather than `lost` or `-1`; also exercise cancellation and broker-restart loss.
