## Context

See `proposal.md` for the motivation and scope. The investigation uses published identity revision `b03fb7ec0963c3ef86d8b92dc1378cf883e8bf16`, plus separately identified Jellyfin/media preparation work. It does not treat stale comparison workspaces or active OpenSpec deltas as current contracts.

Nix currently generates the fleet, pinned workload artifacts, and canonical YAML. `modules/tests` mixes evaluation assertions, local executable checks, Kubernetes API/controller scenarios, and host-level NixOS VMs. `modules/flake/kubernetes-manifests.nix` mixes structural YAML checks with useful cross-object ownership and lifecycle rules. `modules/flake/ci.nix` selects hosted checks partly through metadata naming; a derivation existing does not establish that its behavior runs in required CI.

The latest observed identity CI run took about 55 minutes, with ARM64 packages taking 52m28s. That is not evidence that VM tests caused that run's critical path. This change measures verification costs rather than attributing all CI latency to VMs.

## Goals / Non-Goals

**Goals:**

- Give each safety claim the cheapest layer capable of observing its failure.
- Delete assertions that do not establish a meaningful boundary; demonstrate sensitivity before replacing useful checks.
- Keep schema, policy, API admission, controller behavior, application integration, and host recovery evidence distinguishable.
- Make missing coverage fail rather than silently produce a green run.

**Non-goals:**

- Deploying Kyverno controllers or new production admission restrictions.
- Reimplementing upstream applications or testing all their internals.
- Replacing Incus/mount/ID-map/recovery evidence with a generic Kubernetes cluster.
- Adding every available linter, a new testing abstraction framework, or blanket retry logic.

## Decisions

### 1. Keep Nix as the artifact and configuration layer

Keep negative tests for custom placement, access resolution, capability, path, and credential-ownership rules. Keep one canonical manifest freshness check: it detects deployed Git content diverging from Nix intent. Do not present freshness as runtime proof.

Keep local Go/filesystem tests for ownership refusal, unsafe path handling, ID-map overflow, operation cancellation, and preserving existing state. Controlled HTTP fakes are appropriate when testing our adapter's refusal or state machine; a callback that merely records its own invocation is not equivalent evidence.

### 2. Adopt Kubeconform for structure, with complete input accounting

Use pinned Kubeconform and the target Kubernetes schema version. Fetch built-in schemas by immutable registry revision/hash; derive custom schemas from the exact tracked CRDs. Check-time schema access is local-only, without an implicit remote fallback. Preserve original YAML parsing so duplicate-key errors are not normalized away before validation.

Require every nonempty effective deployment document to be accounted for, with zero unexplained skips, invalid documents, or missing schemas. Validate a deliberately malformed document, an absent custom schema, an empty input, and a skipped-GVK mutation against the final wrapper.

CustomResourceDefinition envelopes need the official versioned local schema and its `_definitions.json`: the standalone strict registry deliberately omits recursive CRD schemas. This envelope schema is not fully strict. Extracted custom schemas also do not implement complete ObjectMeta validation, CEL, structural-schema admission, pruning/defaulting, immutable updates, or controller behavior. Preserve meaningful metadata/policy guards and add API admission evidence rather than claiming `-strict` closes those gaps.

Prefer the maintained upstream converter; verify its behavior on the actual CRDs. The investigation used the tagged Python converter successfully, including a nested HTTPRoute backend typo rejection. Do not generalize that one example to all `allOf`/`anyOf` or extension behavior.

Alternative: keep hundreds of generic shape/type checks in embedded Python. Rejected where independently validated schemas cover them; keep domain-specific joins that schemas cannot express.

### 3. Pilot Kyverno CLI policy; do not mandate a wholesale rewrite

The pilot covers retained deletion protection and administrator-route/policy coupling using actual rendered resources and representative broken variants. Run offline, without Kyverno controllers or access to production. Require explicit expected rule/resource outcomes, including failures when the selected resource or rule disappears. Use `--require-tests`; for `apply`, disallow continuing on evaluation errors and reject zero matching passes. A global pass count alone does not prove every required rule matched.

Keep existing Python for cross-application ownership, path confinement, AppProject authority and manifest coverage until a policy replacement is demonstrably simpler and catches the same negative cases. Kyverno supports offline context evaluation, but this does not establish live RBAC, API availability, background reconciliation or admission-webhook behavior.

Alternatives: Conftest/OPA can express bundle-wide semantic joins, but introduces another language and the same selection hazards. Do not adopt both policy engines. Native Kubernetes CEL/ValidatingAdmissionPolicy is preferable to another controller for any separately approved, sufficiently simple live admission rule. This slice adds no live rule.

### 4. Use Chainsaw for focused real Kubernetes scenarios

Chainsaw runs independently of Kyverno. Use a disposable target-version K3s cluster with explicit kubeconfig/context and pinned artifacts. Install only the real controllers needed by each scenario. Namespace isolation supports parallel namespaced cases; CRD updates, cluster-scoped policies and shared-controller configuration require exclusive fixtures.

Initial candidates:

- API admission: valid resources accepted, invalid CEL/immutable updates denied for the intended reason, prior state preserved.
- Runtime-Secret ownership: execute the actual reconciliation script against a real API; preserve foreign keys and replacement UIDs, reject malformed inventory before mutation. Keep a separate small systemd/host-delivery seam.
- Gateway behavior: actual Accepted/ResolvedRefs/Programmed conditions, trusted versus denied traffic, hostname/CA failures, queryless logs, and authorization boundaries. A schema or `kubectl get` success is insufficient.
- Argo behavior: failed child prevents progress, missing dependencies do not become false Healthy, deleted workload is recreated, and retained state is not cascaded away. Test observed outcomes rather than exact wave strings.

Use exact identities and generation-aware status. Label-selector assertions can be existential; they do not prove all matching objects satisfy a condition. Assert the selected population when the claim is universal. Expected admission rejection must assert the intended reason, not accept any connection error. Unexpected skipped tests or an empty report fail the gate.

Alternatives: existing Python is still appropriate for native application API reconciliation and POSIX/file behavior. Do not port it solely to change syntax. Kind is suitable for generic API/controller scenarios only with an explicitly suitable CNI; it does not automatically reproduce K3s network policy. Envtest lacks kubelet/data-plane/host behavior and is not the default for this deployed third-party stack.

### 5. Keep narrow host and recovery VMs

Retain Linux runtime coverage for whole-root mount identity and disappearance, the retained marker guard, UID/GID mappings, MergerFS/XFS hardlinks and permissions, read-only mounts, nftables source addresses, service activation and actual guest replacement. Schema and policy tools cannot observe these behaviors.

Remove ordinary Kubernetes/application configuration checks from a broad recovery scenario only after a focused replacement proves them. Keep one real destructive-lifecycle acceptance path demonstrating changed disposable guest/control-plane identity and preserved application identity/data. Do not claim a generic Docker bind mount proves Incus propagation.

### 6. Delete vacuity without deleting useful selection guards

Initial deletion/repair inventory:

| Location | Action | Evidence that remains or replaces it |
| --- | --- | --- |
| `kubernetes-manifests.nix`: exact `expected_health_lua` equality | Delete source pin; execute rendered Lua for absent/Healthy/Degraded child status | An always-Healthy mutation fails; real Argo scenario covers scheduling/health interaction |
| `identity-contracts.nix`: exact phase enum and duplicate Job-presence assertion | Delete duplicate/type-copy assertions | Keep phase-specific absence/presence, grant, trust and protection invariants |
| `placement-contracts.nix`: shallow renderer `tryEval` success | Delete bare-not-throw proof | Force the relevant output and assert the capability boundary; empty renderer must fail if that behavior is claimed |
| `default.nix`: timezone projection, preferred shell and exact maintenance defaults | Delete incidental preference pins | Keep account ownership/ACL and storage-secret restart safety |
| `mergerfs-contracts.nix`: exact service-name hash strings | Delete implementation pins | Keep distinct-path collision regression and unsafe-placement rejection |
| `public-edge-contracts.nix`: source-infix header/TLS tests | Remove when actual request/handshake scenario covers the boundary | Keep untrusted CA/name and spoofed-header negatives; add log-leak proof before removing its only evidence |
| `runtime_secrets_test.go`: callback-only empty-generation acknowledgment | Delete invocation echo | Execute stale/missing/exact acknowledgment boundary; retain real SSA/UID tests |
| `adoption_test.go`, `agenix-restart-guard.nix`, storage shell tests | Delete prose/source/default pinning, not refusal/lifecycle tests | Preserve no-write-on-refusal, actual restart counts and real copy integrity |
| Jellyfin/media suites after integration | Remove host-write/read-back and forwarded-fixture copies; fix zero-library/nonempty-profile claims | Verify actual native libraries/scores, data preservation, wrong credentials, and real process access |

A meaningful nonempty-selection guard is not itself vacuous when it prevents a claimed safety rule from checking no targets. The problem is treating nonempty output as the behavior being proved. Likewise, exact allowlists can be genuine security boundaries, not merely copies.

Do not replace source equality with another framework's source equality. Remove orphaned helpers and fixtures when their only assertion is deleted. No percentage-deletion target.

### 7. Enforce evidence and measure the actual critical path

Separate required fast artifact/policy checks from focused Kubernetes/application scenarios and host/recovery jobs. Required scenario identities must appear in both the evaluated CI projection and executed reports. Avoid copying the entire incidental check list; protect the small set of safety capabilities whose omission would invalidate acceptance. Manual single-check dispatch is not full verification.

For migrated checks, record setup/download time separately from scenario time and compare the same observable behavior before and after. Report cache conditions, architecture and external-fetch failures. Use bounded readiness conditions; do not rerun deterministic failures until green. Keep failed-run artifacts sanitized and preserve the first failure classification.

## Exercised investigation evidence

Tools: pinned nixpkgs Kubeconform 0.8.0, Kyverno CLI 1.19.0, and `kyverno-chainsaw` 0.2.15. `chainsaw` without the Kyverno prefix is a different Nix package. Measurements are individual local ARM64 runs, not benchmark medians or promised CI savings.

- Actual 181-document provisioning corpus: 181 valid, zero invalid/errors/skips. With custom schemas and CRD envelope prepared, first complete run 0.765s and warm run 0.361s. Independent document inventory matched. This was a cached, immutable-URL-backed experiment; the proposed fully offline Nix check is not implemented yet.
- Actual Deployment: misspelled security field rejected. Unknown custom schema failed. With `-ignore-missing-schemas`, the unknown resource instead returned success with one skip. Empty input returned success with zero checked resources.
- Actual CRD: missing required `spec.group` rejected; additional misspelled envelope field accepted by the official non-strict envelope schema. This is a documented validation boundary, not permission to omit CRDs.
- Actual retained PV policy: good input passed; removing `Delete=false` failed. Unrelated resource failed when zero-match protection was enabled. Runs took about 0.34–0.71s.
- Kyverno empty suite returned success by default and failed with `--require-tests`. Chainsaw empty suite returned success with passed/failed/skipped all zero.
- Isolated local K3s `v1.35.8+k3s1`: original Gateway passed schema and server dry-run. Changing HTTPS to HTTP while retaining TLS passed schema but the real API rejected it through the deployed CRD's CEL rule.
- Chainsaw against that real API: one scenario passed in 10.322s, checking valid creation, specific rejection, and preserved prior state. Removing the actual CEL rule made the same scenario fail in 13.862s with false rejection assertions. No controller or packet-path proof is claimed by this API experiment.
- Disposable cluster, anonymous volumes and kubeconfig were removed. No production cluster, credentials, host mounts or deployment were changed.

## Risks / Trade-offs

- Schema green mistaken for deployed correctness → retain CEL/API, controller, data-plane and host evidence as separate gates.
- Test migration erases the only useful negative → prove replacement sensitivity before removing that check.
- New framework adds more maintenance than it removes → keep the pilot bounded and preserve simpler existing code when it wins.
- Shared cluster makes parallel tests interfere → isolate namespaces and serialize shared/cluster-scoped mutations.
- Image/schema fetches dominate reliability → pin inputs and preload/fetch in explicit setup, never hide admission or configuration failures behind retries.
- Faster individual checks do not shorten package-dominated CI → measure and report critical-path effects separately.

## Migration Plan

1. Rebase onto the accepted application integration; preserve original branch provenance while investigating.
2. Delete unambiguously incidental assertions; replace source-text safety claims with executable behavior. Keep all useful safety gates active.
3. Land complete schema validation and negative coverage, then remove only structural guards it demonstrably subsumes.
4. Pilot offline semantic policy and focused Chainsaw scenarios. Compare against existing evidence and measurements before moving their required CI gates.
5. Narrow heavyweight VM scenarios only after their non-host portions have equivalent required coverage. Keep full recovery acceptance.
6. Roll back tooling by reverting its commits and restoring the previous required checks, not by disabling failed gates or changing production desired state.

## Sources

- [Kubeconform usage and limitations](https://github.com/yannh/kubeconform/blob/v0.8.0/Readme.md)
- [Pinned CRD converter](https://github.com/yannh/kubeconform/blob/v0.8.0/scripts/openapi2jsonschema.py)
- [Recursive CRD schema limitation](https://github.com/yannh/kubeconform/issues/100)
- [Pinned Kubernetes schema registry](https://github.com/yannh/kubernetes-json-schema/tree/8df8a883b68a24a104b4a9e43c1288090ae60b3b)
- [Kyverno CLI](https://kyverno.io/docs/subprojects/kyverno-cli/) and [test options](https://kyverno.io/docs/kyverno-cli/reference/kyverno_test/)
- [Chainsaw assertions](https://kyverno.github.io/chainsaw/0.2.15/quick-start/assertion-trees/) and [expected operation errors](https://kyverno.github.io/chainsaw/0.2.15/operations/apply/)
- [Kubernetes server dry-run](https://kubernetes.io/docs/reference/using-api/api-concepts/#dry-run) and [native admission policy](https://v1-35.docs.kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
- [Conftest combined inputs](https://www.conftest.dev/options/), [kube-linter configuration](https://github.com/stackrox/kube-linter/blob/main/docs/configuring-kubelinter.md), and [kube-score](https://github.com/zegl/kube-score)
