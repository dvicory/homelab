## 1. Broker Workspace Store

- [ ] 1.1 Add the `hvn-hyp1` QA broker workspace schema, clean legacy migration, broker-owned path validation, and lifecycle service under `pkgs/by-name/gondolin-broker-effect`; run focused package tests and the Nix package check, then commit the self-contained change with a conventional commit message. No SOPS update.
- [ ] 1.2 Add strict control-plane workspace acquire/describe/list/release/close/delete schemas and routes under `pkgs/by-name/gondolin-broker-effect`; verify route separation and lifecycle failures with focused tests and the Nix package check, then commit. No SOPS update.

## 2. Gondolin Environment Binding

- [ ] 2.1 Replace `workspace_path` environment storage with workspace/lease references, validate the active lease during ensure/reuse, and mount only the internally derived directory under `pkgs/by-name/gondolin-broker-effect`; verify persistence across VM recreation plus stale/conflicting lease denial with focused tests and the Nix package check, then commit. No SOPS update.

## 3. Hermes Trusted Integration

- [ ] 3.1 Extend the repository-owned sandbox-access plugin/client in `pkgs/by-name/hermes-agent-patched` with trusted workspace acquire/release and authority registration; verify strict byte-safe Unix-socket contracts and run its focused Nix check, then commit. No SOPS update.
- [ ] 3.2 Add nullable `sandbox_workspace_id` persistence and Gondolin-only acquisition/reuse/release to Hermes Kanban dispatch under `pkgs/by-name/hermes-agent-patched`, keeping model schemas and non-Gondolin behavior unchanged; run focused Kanban/plugin tests and the Nix package check, then commit. No SOPS update.

## 4. QA Activation and Acceptance

- [ ] 4.1 Wire the workspace lifecycle configuration through `modules/den/aspects/workloads/hermes/secure-terminal` and `modules/den/users/hermes-runners.nix` for `hvn-hyp1` QA only; evaluate the host and build focused broker/Hermes checks, then commit. No SOPS update.
- [ ] 4.2 Deploy only the `hvn-hyp1` QA profile and exercise clean legacy removal, first task acquisition, same-task retry, VM recreation with retained bytes, conflicting writer denial, completion release, explicit deletion, and unchanged non-Gondolin behavior; record observed evidence in the V3/OpenSpec docs and commit the acceptance record.