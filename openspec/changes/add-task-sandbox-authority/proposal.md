## Why

The QA Gondolin broker currently treats a client-supplied worklane as policy authority and can only apply a fixed network policy when a VM is created. Hermes needs task-scoped, user-approved runtime capabilities so an agent can discover a denied operation, request the smallest missing authority, receive approval without a Nix redeploy, and retry in the same VM without gaining arbitrary policy control.

## What Changes

- Replace client-selected worklane authority with broker-owned task/environment authority bindings.
- Separate executor routing (Hermes profile or worker lane) from sandbox authority classes.
- Add typed, batchable runtime capability requests. The broker protocol supports once, task, conversation, timed, profile, and executor scopes, but the QA Hermes integration exposes only once and task where Nix policy permits.
- Add live activation, revocation, expiry, immutable-policy-digest binding, and broker-side remembered-grant machinery for future management clients. QA Hermes cannot create durable remembered grants. Network grants take effect in the existing VM; structural changes recreate the VM.
- Add structured requestable denials so the agent can learn which capability is missing and retry after approval.
- Add approval-fatigue controls: one pending request per task, request coalescing, denial cooldowns, prompt budgets, and canonical broker-rendered policy diffs.
- Add a privileged broker control channel for authority registration and grant mutation; the ordinary execution channel cannot select its own authority.
- Add a Nix-managed Hermes sandbox-authority plugin that uses existing tool registration, task lifecycle hooks, and approval UX.
- Make one narrow, generic Hermes integration change so an authority-bearing task receives a distinct canonical environment identity. No policy evaluator or per-tool worklane plumbing is added to Hermes.
- Add exact public and private HTTP(S) origin grants as the first dynamically enforceable capability. The schema remains extensible to installed credential adapters, filesystem exports, resources, and exact TCP mediation without treating unsupported capability kinds as approved no-ops.
- Amend `HERMES_NIX_SECURE_TERMINAL_BACKEND_V3.md` and the Agent-X broker/policy documentation to define defaults, operator overrides, hard enforcement boundaries, and dynamic grant semantics.
- **BREAKING**: remove the untrusted `worklane` field from the ordinary environment `ensure` authority contract. Existing fixed-policy QA callers fall back to the broker-configured profile default.

## Capabilities

### New Capabilities

- `task-sandbox-authority`: Broker-owned binding of trusted profile, executor, task identity, environment identity, authority class, and immutable policy digest.
- `runtime-capability-grants`: Typed activation, lookup, expiry, revocation, remembered rules, live network-policy evaluation, and structural-change generation behavior.
- `sandbox-access-approval`: Agent discovery/request/retry flow, canonical approval presentation, grant scopes, batching, and approval-fatigue controls through a Hermes plugin.

### Modified Capabilities

None. This repository has no existing OpenSpec capability baseline for the experimental secure-terminal broker.

## Affected Configurations

- QA host `hvn-hyp1` and the `hermes-qa` profile only.
- `pkgs/by-name/gondolin-broker-effect` and its embedded Agent-X policy kernel.
- `modules/den/aspects/workloads/hermes/secure-terminal/` policy, network, service, and profile integration.
- `pkgs/by-name/hermes-agent-patched` only for a generic trusted task-environment authority identity hook.
- A new or existing Nix-managed Hermes plugin package for sandbox authority and approval orchestration.
- `modules/tests/secure-terminal-policy.nix` and package contract/smoke checks.
- No nix-darwin or home-manager runtime behavior outside package evaluation checks.

## Non-goals

- Shipping a new credential secret or service-specific credential adapter in this change.
- Passing gateway credentials or raw secrets into a guest.
- Treating approval as permission to disable mediation, audit, resource hard limits, or broker isolation.
- Dynamically changing QEMU arguments, guest kernels/assets, arbitrary host mounts, or unsupported protocols.
- Production cutover or removal of the rootless-Podman comparison path.
- Solving Gondolin PTY/background-process parity beyond the existing QA compatibility work.

## Technical Assumptions

- Gondolin HTTP/DNS enforcement hooks can consult broker-owned mutable grant state on every request without exposing a general guest network interface.
- The paired Hermes user and configured local operator are trusted approval principals; model-authored text is not trusted approval evidence.
- Hermes plugin handlers receive trusted task/session identity and can call the existing approval API without modifying every environment-backed tool.
- The gateway dispatcher can register worker defaults before spawn through an existing task lifecycle hook.
- Runtime grant state is persisted in the broker registry and remains subordinate to the current immutable Nix policy digest and broker enforcement capabilities.
- Exact private HTTP(S) origins may be approved dynamically, but redirects, DNS answers, and resolved addresses remain bound to the approved origin and port.
- Unsupported capability kinds fail closed and cannot become effective solely because a user clicked approve.

## Refactoring

The broker authority boundary is refactored from `ensure(environmentKey, worklane)` to an execution-plane `ensure(environmentKey)` plus control-plane authority binding and grant operations. This is independently justified because a client-selected worklane conflates routing metadata with authorization and cannot safely support concurrent tasks in one Hermes gateway process.

Hermes environment identity gains one generic infrastructure-only authority binding hook. This is preferred over Gondolin-specific parameters across terminal, file, patch, search, process, and execute-code handlers and should remain upstreamable.

## Rollback

- Keep production unchanged throughout the QA implementation.
- Gate dynamic authority/grants behind the `hermes-qa` secure-terminal configuration.
- On failure, disable the sandbox-authority plugin and control socket, clear or quarantine runtime grants, and return the QA broker to its fixed `project` default policy.
- If broker/runtime compatibility regresses, switch QA back to the existing rootless-Podman backend while retaining registry/audit data for diagnosis.
- Never migrate gateway credentials or canonical workspace state into the experimental broker, so rollback does not require secret rotation or data recovery.
