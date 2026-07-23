## 1. Broker Workspace Store

- [x] 1.1 Add the `hvn-hyp1` QA broker workspace schema, clean legacy migration, broker-owned path validation, and lifecycle service under `pkgs/by-name/gondolin-broker-effect`; run focused package tests and the Nix package check, then commit the self-contained change with a conventional commit message. No SOPS update.
- [x] 1.2 Add strict control-plane workspace acquire/describe/list/release/close/delete schemas and routes under `pkgs/by-name/gondolin-broker-effect`; verify route separation and lifecycle failures with focused tests and the Nix package check, then commit. No SOPS update.

## 2. Gondolin Environment Binding

- [x] 2.1 Replace `workspace_path` environment storage with workspace/lease references, validate the active lease during ensure/reuse, and mount only the internally derived directory under `pkgs/by-name/gondolin-broker-effect`; verify persistence across VM recreation plus stale/conflicting lease denial with focused tests and the Nix package check, then commit. No SOPS update.

## 3. Hermes Trusted Integration

- [x] 3.1 Add the repository-owned `workspace-service` lifecycle plugin in `pkgs/by-name/hermes-agent-patched` for trusted acquisition, authority registration, conventional `/workspace` context, and fail-closed execution preflight; verify strict Unix-socket contracts and run its focused Nix check, then commit. No SOPS update.
- [x] 3.2 Add the generic `prepare_worker_environment` plugin hook and Gondolin-only Kanban acquisition/handoff under `pkgs/by-name/hermes-agent-patched`; pass only opaque workspace/lease IDs plus `/workspace`, remove host workspace paths, keep model schemas and non-Gondolin behavior unchanged, run focused Kanban/plugin tests and the Nix package check, then commit. No SOPS update.

## 4. QA Activation and Acceptance

- [x] 4.1 Wire the workspace lifecycle configuration through `modules/den/aspects/workloads/hermes/secure-terminal` and `modules/den/users/hermes-runners.nix` for `hvn-hyp1` QA only; evaluate the host and build focused broker/Hermes checks, then commit. No SOPS update.
- [ ] 4.2 On `hvn-hyp1` QA, verify clean legacy removal, first task acquisition, same-task retry, VM recreation with retained bytes, conflicting writer denial, terminal-state VM close with retained task lease, explicit release and deletion, fail-closed broker outage, and unchanged non-Gondolin behavior; fix broker-aware cached preflight, record observed evidence in the OpenSpec design, run focused checks, request approval before redeployment, and commit the acceptance record.