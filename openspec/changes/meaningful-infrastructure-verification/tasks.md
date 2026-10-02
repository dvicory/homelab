## 1. Establish the accepted baseline and evidence map

- [ ] 1.1 Rebase the slice onto the accepted application integration without importing temporary rollout refs; verify current contracts, generated-manifest freshness and preserved unrelated changes at the resulting exact revision.
- [ ] 1.2 Reconcile the design's deletion inventory against that revision, including current Jellyfin/media tests rather than stale comparison workspaces; record each assertion's claimed failure, observed boundary and keep/delete/replace decision.
- [ ] 1.3 Capture baseline timings and executed scenario identities for the targeted checks, separating setup/downloads, execution, architecture, cache state and external failures; do not classify an unexecuted derivation or a timeout limit as runtime evidence.

## 2. Remove vacuous assertions and replace misleading safety claims

- [ ] 2.1 Delete incidental timezone/shell/maintenance defaults, exact service-name hashes, duplicate Job/enum presence checks and shallow renderer-success assertions; remove dead fixtures and verify the remaining custom Nix/Den negative checks still reject unsafe input.
- [ ] 2.2 Replace exact Argo health Lua text equality with execution of the rendered script for absent, Healthy and Degraded child status; verify an always-Healthy mutation fails and harmless implementation formatting does not fail.
- [ ] 2.3 Delete callback-only acknowledgment and diagnostic/source-text pinning in the scoped Go/storage tests; execute missing/stale/exact acknowledgment and refusal-before-mutation cases to verify the actual safety boundary remains covered.
- [ ] 2.4 Remove public-edge source-string assertions already subsumed by actual handshake/request checks; add the missing log-leak/request-ID behavior before removing its only current evidence, and verify untrusted TLS/spoofed requests are rejected or sanitized as intended.
- [ ] 2.5 Remove Jellyfin/media forwarding and host-write/read-back self-checks after integration; verify required native libraries/profiles/scores, unchanged unmanaged data and real process access with a representative missing-library/wrong-score/denied-access case.

## 3. Add complete schema validation

- [ ] 3.1 Pin Kubeconform, the target-version built-in registry, exact tracked CRD inputs and upstream converter through Nix; verify schema derivation reproducibility and local-only check execution without remote fallback.
- [ ] 3.2 Include the official local CRD-envelope schema and its definitions; inventory served custom GVKs and reject missing or colliding schema outputs. Verify both a malformed envelope and a missing custom schema fail, while documenting the envelope's extra-field limitation.
- [ ] 3.3 Validate original canonical YAML with strict parsing and independent effective-document coverage; verify malformed fields, duplicate keys, empty/comment-only input and an all-skipped selection cannot produce a successful repository gate.
- [ ] 3.4 Remove only mapping/list/type assertions independently subsumed by the new schema gate; mutate representative Application/AppProject field classes to prove the replacement rejects them, and retain metadata, retention, source confinement, ownership and authority rules not covered by schemas.

## 4. Pilot semantic policy without a production controller

- [ ] 4.1 Run a pinned Kyverno CLI pilot on actual rendered retained resources and administrator-route/policy pairs; verify allowed input passes and missing deletion protection, missing policy, wrong phase and missing selected resources fail for the intended rule.
- [ ] 4.2 Make missing tests, unexpected skips, evaluation errors and missing required rule/resource outcomes fail; verify deletion of the policy/rule/fixture or a mismatched selector cannot turn the policy gate green.
- [ ] 4.3 Compare the pilot with existing Python/Nix semantic checks and keep the simpler implementation for each boundary; verify no policy is enforced by duplicate independent definitions and no meaningful cross-object rule disappears in the migration.

## 5. Add focused real API and controller scenarios

- [ ] 5.1 Provide an isolated pinned target-version K3s fixture with explicit kubeconfig/context, bounded readiness and reliable cleanup; verify a failed scenario removes its owned cluster resources without addressing production or exposing credentials.
- [ ] 5.2 Add Chainsaw admission coverage using the actual Gateway CRD: valid resource admitted, HTTP-with-TLS mutation rejected for the intended reason and prior state preserved. Remove the relevant CEL rule in a disposable fixture and verify the scenario fails.
- [ ] 5.3 Move the runtime-Secret SSA/UID ownership scenarios to focused real-API execution of the production script; verify foreign keys and replacement objects survive, malformed inventory fails before mutation, and preserve a small separate host/service delivery test.
- [ ] 5.4 Exercise the actual Argo controller's failed-child health, dependency/hook sequencing, self-heal and retained-resource lifecycle in a focused disposable fixture; verify a deliberately broken health/preservation rule fails rather than only asserting annotation values.
- [ ] 5.5 Exercise Gateway policy with the real controller and CNI: allowed/denied clients, missing grant, bad backend hostname/CA, authorization and queryless logging; verify actual traffic and generation-aware status, not only applied resource existence.
- [ ] 5.6 Make Chainsaw reports enforce expected scenario identities and reject zero selection or unexpected skips; verify empty directories, exclusion selectors and nonexistent labels cannot satisfy the gate.

## 6. Integrate CI and narrow expensive scenarios safely

- [ ] 6.1 Register required fast, Kubernetes/application and host/recovery gates explicitly in hosted CI; remove reliance on incidental metadata suffixes for safety-critical selection and verify removing a required scenario registration fails before reporting success.
- [ ] 6.2 Enforce the native media API scenario on the accepted media revision; verify wrong credentials/configuration fail and intended native state persists without relying on successful log phrases or nonempty collections.
- [ ] 6.3 Remove migrated Kubernetes-only portions from broad VM scenarios only after equivalent required replacement coverage passes; run retained host mount/ID-map/filesystem/firewall/service and full guest-recovery scenarios to verify no safety seam was discarded.
- [ ] 6.4 Run the selected checks against the exact proposed Git revision, with negative mutations and sanitized result artifacts; compare equivalent baseline/candidate setup and execution timings and report reliability limits without claiming an unmeasured speedup.
- [ ] 6.5 Update existing verification/CI documentation to name what each gate proves, exclusions and reproduction commands; validate OpenSpec planning consistency and confirm no production policy or desired-state change was introduced by the tooling slice.
