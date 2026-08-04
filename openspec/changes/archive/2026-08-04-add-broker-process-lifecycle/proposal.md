## Why

Hermes currently implements non-local background commands by writing PID, output, and exit files into a Gondolin guest's ephemeral `/tmp` and reconstructing lifecycle state through later executions. A live QA run proved that the durable workspace side effect can survive while the authoritative exit status is reported as `lost`; background process authority therefore belongs in the broker, not in model-writable guest storage.

## What Changes

- Add a broker-owned process resource with an opaque process ID bound to the exact environment key, generation, task-run activation, workspace lease, authority class, and policy digest.
- Add authenticated spawn, combined poll, and cancel operations. The broker retains the Gondolin execution handle in an application-scoped Effect fiber, stores bounded output and the exact terminal result in memory, and never asks Hermes to infer completion from guest PID or sentinel files.
- Define explicit running, exited, cancelled, and lost states with real exit code/signal, bounded stdout/stderr, and monotonic output cursors.
- Fence process operations when the task-run authority, workspace lease, or VM generation is stale. Environment close and task completion cancel and drain owned processes before releasing or freezing mutable storage.
- Treat broker or VM restart as explicit process loss. Running processes and in-memory terminal records are broker-lifetime resources; the implementation does not add a durable process database or claim restart-resumable execution.
- Patch Hermes' Gondolin background/process path to use only the broker process API. Remove the `/tmp/hermes_bg_*`, guest-PID polling, and fabricated `exit_code=-1` compatibility path for Gondolin without changing local, Docker, Podman, SSH, or other backends.
- Add real-Gondolin acceptance for nonzero exit, bounded output, cancellation, gateway disconnect, broker restart loss, generation replacement, and stale authority.

## Capabilities

### New Capabilities

- `sandbox-process-lifecycle`: Broker-owned, broker-lifetime asynchronous execution, bounded output, status, cancellation, generation fencing, and cleanup for Gondolin environments.

### Modified Capabilities

- `kanban-sandbox-workspace`: Process operations use the same frozen task-run workspace and authority as every other worker surface; completion, block, timeout, and reclaim have explicit running-process behavior.
- `sandbox-workspace-lifecycle`: Environment generation replacement, workspace release, and branching cancel and drain in-memory process resources without stale-handle reuse.
- `task-sandbox-authority`: Process spawn, poll, and cancel requests are authorized against trusted task-run bindings and cannot accept model-selected authority fields.

## Impact

- Gondolin Effect broker execution primitive, application-scoped process registry, HTTP routes, policy limits, and audit events.
- Patched Hermes Gondolin environment and process registry integration.
- Secure-terminal Nix policy configuration for concurrent-process, output, and retention limits.
- Broker, patched-Hermes, Nix, and live QA acceptance coverage.
- No API compatibility is promised for the unreleased guest-file-backed Gondolin background implementation; it is removed in one cutover.
