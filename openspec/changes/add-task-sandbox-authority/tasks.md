## 1. Credential-Free Baseline

- [x] 1.1 Complete and commit the `hvn-hyp1` QA broker's policy-backed Gondolin HTTP/DNS enforcement, including exact public origins, internal-range denial, worklane attenuation fixtures, and the targeted broker/Nix rebuild checks.
- [x] 1.2 Route Hermes patch pre-read, write, and byte verification through typed broker file operations instead of PTY shell output; prove exact non-ASCII/control-byte round trips with the patched-source and broker checks, then commit the repair.

## 2. Broker Authority Boundary

- [x] 2.1 Add strict task authority binding schemas and SQLite persistence in `pkgs/by-name/gondolin-broker-effect`, remove caller-selected worklane authority from execution `ensure`, cover default/conflicting bindings, run the package check, and commit.
- [x] 2.2 Add named systemd-activated execution/control listeners and route-level separation for the `hermes-qa` broker on `hvn-hyp1`; extend activation and Nix HTTP checks for both descriptors, rebuild them, and commit. No SOPS update is required.

## 3. Dynamic Runtime Grants

- [ ] 3.1 Add closed `network-origin` capability decoding, canonical public/private origin preparation, private-address pin previews, batch deduplication, and stable unsupported-capability failures; run broker contract checks and commit.
- [ ] 3.2 Add strict SQLite access-request/runtime-grant tables, transactional scope/expiry/revocation/once-use behavior, remembered profile/executor rules, policy-generation invalidation, atomic in-memory snapshots, cooldown/coalescing/prompt-budget state, focused checks, and commit.
- [ ] 3.3 Compose active grants into Gondolin DNS/HTTP hooks so approved public and pinned-private origins activate and revoke in the same VM while redirects and rebinding remain constrained; add structured requestable denials, run broker checks, and commit.

## 4. Minimal Hermes Integration

- [ ] 4.1 Add one generic infrastructure-only Hermes task authority binding hook to canonical environment identity, migrate no individual tool schemas, exercise concurrent task separation through the patched-source check, and commit.
- [ ] 4.2 Add a Nix-built sandbox-authority Hermes plugin with control client, `sandbox_request_access`, list/revoke tools, existing approval-provider integration, trusted session/Kanban registration, canonical batch prompts, suppressed-request handling, plugin contract checks, and commit.
- [ ] 4.3 Wire the plugin, profile/executor defaults, allowed grant scopes, cooldowns, budgets, and control socket into `modules/den/aspects/workloads/hermes/secure-terminal/` for `hermes-qa`; rebuild the affected `hvn-hyp1` configuration and portable checks, then commit. No SOPS update is required.

## 5. End-to-End Validation and Documentation

- [ ] 5.1 Exercise a real broker path covering denied origin, canonical capability preparation, approval decision, same-generation retry, live revocation, expiry/restart, concurrent authority isolation, fatigue suppression, and byte-safe patching; commit any focused regression repairs individually.
- [ ] 5.2 Amend `HERMES_NIX_SECURE_TERMINAL_BACKEND_V3.md` and Agent-X broker/policy documentation with sandbox classes, dynamic grants, hard enforcement boundaries, approval scopes/fatigue controls, mutable overlay operations, rollback, and the exact Hermes patch surface; run documentation/package checks and commit.
- [ ] 5.3 Deploy only the QA `hvn-hyp1` profile, run the Hermes-agent prompt/scenario against default, dynamically approved public/private, revoked, and denied paths, record observed compatibility without production changes, and commit the verified final configuration.
