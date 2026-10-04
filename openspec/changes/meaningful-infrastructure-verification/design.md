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
- Prefer maintained Kubernetes-native verification and enduring policy enforcement over custom Python/Nix validators and Kubernetes-only VM orchestration; delete replaced implementations.

**Non-goals:**

- Deploying Kyverno controllers or new production admission restrictions.
- Reimplementing upstream applications or testing all their internals.
- Replacing Incus/mount/ID-map/recovery evidence with a generic Kubernetes cluster.
- Adding every available linter, a new testing abstraction framework, or blanket retry logic.

## Decisions

### 1. Keep Nix as the artifact and configuration layer

Keep meaningful rejection tests for custom placement, access resolution, capability, path, and credential-ownership inputs that cannot be established from rendered Kubernetes resources. Do not classify rendered policy as Nix-only merely because its current assertion reads an intermediate Nix object. Keep one canonical manifest freshness check: it detects deployed Git content diverging from Nix intent, not runtime behavior.

Keep local Go/filesystem tests for ownership refusal, unsafe path handling, ID-map overflow, operation cancellation, and preserving existing state. Controlled HTTP fakes are appropriate when testing our adapter's refusal or state machine; a callback that merely records its own invocation is not equivalent evidence.

### 2. Adopt Kubeconform for structure, with complete input accounting

Use pinned Kubeconform and the target Kubernetes schema version. Fetch built-in schemas by immutable registry revision/hash; derive custom schemas from the exact tracked CRDs. Check-time schema access is local-only, without an implicit remote fallback. Preserve original YAML parsing so duplicate-key errors are not normalized away before validation.

Require every nonempty effective deployment document to be accounted for, with zero unexplained skips, invalid documents, or missing schemas. Validate a deliberately malformed document, an absent custom schema, an empty input, and a skipped-GVK mutation against the final wrapper.

CustomResourceDefinition envelopes need the official versioned local schema and its `_definitions.json`: the standalone strict registry deliberately omits recursive CRD schemas. This envelope schema is not fully strict. Extracted custom schemas also do not implement complete ObjectMeta validation, CEL, structural-schema admission, pruning/defaulting, immutable updates, or controller behavior. Preserve meaningful metadata/policy guards and add API admission evidence rather than claiming `-strict` closes those gaps.

Prefer the maintained upstream converter; verify its behavior on the actual CRDs. The investigation used the tagged Python converter successfully, including a nested HTTPRoute backend typo rejection. Do not generalize that one example to all `allOf`/`anyOf` or extension behavior.

Alternative: keep generic shape/type checks in embedded Python. Rejected where independently validated schemas cover them. Move meaningful domain-specific joins to Kyverno rather than using schema limitations to retain a second policy engine.

### 3. Make Kyverno the required rendered-resource policy gate

The operator superseded the pilot's decision to keep simpler Python/Nix checks. Ordinary reviewed Kyverno policies, native Tests and required evaluated facts/parameters now own rendered Kubernetes semantic verification. Run the pinned CLI offline against complete canonical resources and genuine initial/provisioning/normal and direct/trusted-edge renders. Require positive and deliberately unsafe cases before deleting equivalent custom assertions, collectors that compute policy verdicts, and dead helpers. Do not introduce a new custom policy framework around the CLI or a copied protocol constant whose only check compares it back to itself.

| Existing verification | Native replacement and deletion boundary |
| --- | --- |
| `kubernetes-manifests.nix` Application lifecycle, source confinement, ownership, retention and AppProject authority | Kyverno resource rules and bundle joins; delete the semantic Python validator. Preserve generation integrity and separately execute the health Lua. |
| `identity-contracts.nix` phase population, administrator membership, route/policy coupling and trust | Phase-aware Kyverno cardinality, absence and reciprocal binding rules; remove rendered-object selectors/assertions. Preserve genuine compute-resource input rejection. |
| `placement-contracts.nix` rendered route/Service/ReferenceGrant validation | Native policy joins; delete `placement_errors` and its custom mutation harness, retaining Nix/Den input semantics. |
| `public-edge-contracts.nix` rendered Gateway identity, TLS, timeout and isolation rules | Kyverno over complete rendered controller/Gateway resources; use Kubeconform for schema checks. Preserve genuine Nginx/NixOS and invalid-input boundaries, not Kubernetes duplicates. |
| `pod-security-contracts.nix` pod/volume identity and secret readability | Native policy over every applicable workload/container kind, with validated mode arithmetic and negative cases; delete the Python scan. |
| Jellyfin/media/media-storage rendered credentials, mounts, retention, exposure and lifecycle rules | Native application/storage policy; delete rendered-resource lookup helpers and assertions. Keep actual bootstrap/initializer execution and application protocol behavior. |

Provide trusted evaluated phase, destination, domain, route, storage and image facts plus complete file/source/bootstrap provenance as policy context. Context collection serializes facts; it must not decide policy, pre-filter unsupported files, collapse duplicate identities or borrow a different phase's resources. Filesystem enumeration and artifact equality cannot be inferred from Kubernetes objects alone. Keep only the necessary packaging/integrity boundary and express authority, ownership and coverage decisions in policy.

Require exact expected policy/rule/resource outcomes, including missing populations. Per-resource selectors cannot detect a vanished resource: use an independently present anchor and explicit population/coverage rules. Use `--require-tests`; reject missing policies, rules, fixtures, required evaluated facts/parameters or expected outcomes, skipped required outcomes, evaluation errors, selector misses and zero matching passes. Native excluded rows outside the independently required outcome set are nonapplicable, not proof; they cannot substitute for any required result. A global pass count is insufficient. Exercise representative retention, authority, route-binding, trust, credential and storage violations against the required gate.

Policies remain required CI enforcement, not scratch pilot strings. Record whether each rule is repository/bundle-only or a candidate for future admission/background enforcement. Resource-local rules may transfer, but Git ownership, exact inventories, phase facts and cross-object joins need different live context and race semantics. Argo `Delete=false` is not an admission DELETE prohibition. This change installs no controller and claims no live enforcement.

If a rendered-resource rule cannot be expressed reliably with supported native features, demonstrate the limitation and obtain an operator decision; do not silently preserve the old engine. Retaining an executed Lua, host-input or real protocol check requires the concrete boundary it observes. Existing implementation size is not an exception.

Alternatives: Conftest/OPA would introduce another policy language and the same selection hazards; do not adopt a second engine. Native Kubernetes CEL/ValidatingAdmissionPolicy remains an option for separately approved live admission requirements, not a replacement for this complete rendered-policy gate.

### 4. Use Chainsaw for focused real Kubernetes scenarios

Reuse the existing `verify-kubernetes-api` disposable, pinned K3s lifecycle and Chainsaw packaging. Extend that fixture for controllers, disposable Git, node-local storage, synthetic trust and browser/network prerequisites rather than adding another runner framework. Replace custom API polling/assertions with native operations and Chainsaw assertions. Namespace isolation supports parallel namespaced cases; CRD changes, cluster-scoped policies and shared-controller configuration require exclusive fixtures.

Required native scenarios:

- API admission: valid resources accepted, invalid CEL/immutable updates denied for the intended reason, prior state preserved.
- Runtime-Secret ownership: execute the exact evaluated production reconciliation script in an owned Linux fixture, with its packaged closure and isolated expected paths. Preserve foreign keys and replacement UIDs, reject malformed inventory before mutation, and cover both same-UID shared and sole-owner TLS retirement. Replace imperative API-test orchestration; keep the small real systemd/host-delivery seam.
- Gateway behavior: actual generation-aware Accepted/ResolvedRefs/Programmed conditions, missing-grant rejection/recovery, TLS name/CA failures/recovery, queryless and credential-free logs, and real authorization. Establish distinct trusted/untrusted connecting addresses and the deployed-family CNI's actual packet enforcement before removing the multi-VM network fixture. Docker port NAT or status-only assertions are not equivalent. Keep real Chromium/WebAuthn/Kanidm/OIDC execution, not mocked claims, while moving fixture orchestration to the shared native runner.
- Argo behavior: current-revision failed/missing-child blocking and recovery, hook sequencing, self-heal, Git omission and direct/root-child retirement with retained identities and usable data. Replace Python polling and VM orchestration after native parity, including health/preservation counterfactuals. Node-local kubelet storage evidence does not replace host adoption or Incus mount/identity proof.

Use exact identities and generation-aware status. Argo success must correlate desired source, resolved revision and operation revision; Healthy alone is insufficient. Label-selector assertions can be existential, so assert the selected population when the claim is universal. Expected rejection must establish the intended reason, not any connection error. Require stable safety-scenario identities and reject omitted, scoped, skipped, failed or empty coverage, missing reports and cleanup failure. Do not pin incidental operation counts or implementation sequences.

Retain a custom executable only for a concrete production algorithm, filesystem or protocol boundary that native resource operations/assertions cannot establish; prefer native assertions for the surrounding Kubernetes state. Existing browser-generated MFA and production bootstrap/initializer execution are such boundaries. Kind or generic Pods are not assumed to reproduce K3s CNI/source-address behavior; envtest lacks kubelet/data-plane/host behavior.

### 5. Keep narrow host and recovery VMs

Retain Linux runtime coverage for whole-root mount identity and disappearance, the retained marker guard, UID/GID mappings, MergerFS/XFS hardlinks and permissions, read-only mounts, nftables source addresses, service activation and actual guest replacement. Schema and policy tools cannot observe these behaviors.

Remove Kubernetes-only bootstrap/publication, self-heal, resource declaration and detailed Argo retirement assertions from broad recovery scenarios once their required native replacements pass. Delete superseded focused VM wrappers, helpers and CI registrations, not only their invocation. Keep startup gates and actual cross-boundary witnesses needed for host measurements: staged credentials, read-only mapped library access, source loss/return and real application state through changed guest/control-plane identity. A generic Docker bind mount is not Incus propagation, and a file sentinel is not persisted application identity or played state.

### 6. Delete vacuity without deleting useful selection guards

Initial deletion/repair inventory:

| Location | Action | Evidence that remains or replaces it |
| --- | --- | --- |
| `kubernetes-manifests.nix`: exact `expected_health_lua` equality and semantic validator | Delete source pin and migrate resource policy to Kyverno; retain direct execution of rendered Lua separately | Broken health behavior fails; real Argo scenario covers scheduling/health interaction |
| `identity-contracts.nix`: phase enum, Job copies and rendered policy | Delete incidental copies; migrate meaningful phase/grant/trust/protection rules to Kyverno | Native positive/negative phase fixtures; genuine Nix input refusals remain |
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

- Actual 181-document provisioning corpus: 181 valid, zero invalid/errors/skips. With custom schemas and CRD envelope prepared, first complete run 0.765s and warm run 0.361s. Independent document inventory matched. These exploratory measurements are not evidence of the later packaged offline gate's runtime.
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
- Migration becomes a second framework or leaves duplicate authorities → use ordinary native policies/fixtures, keep context transport minimal, and delete old validators after equivalent required proof.
- Shared cluster makes parallel tests interfere → isolate namespaces and serialize shared/cluster-scoped mutations.
- Image/schema fetches dominate reliability → pin inputs and preload/fetch in explicit setup, never hide admission or configuration failures behind retries.
- Faster individual checks do not shorten package-dominated CI → measure and report critical-path effects separately.

## Migration Plan

1. Rebase onto the accepted application integration; preserve original branch provenance while investigating.
2. Delete unambiguously incidental assertions; replace source-text safety claims with executable behavior. Keep all useful safety gates active.
3. Land complete schema validation and negative coverage, then remove only structural guards it demonstrably subsumes.
4. Replace rendered semantic validators with required Kyverno policy and native positive/negative coverage across complete phase/mode renders; remove the old rules and helpers once each replacement passes.
5. Extend the existing Chainsaw/K3s fixture for required controller, traffic and exact production-script scenarios. Prove CNI/source-address/browser and Secret packaging prerequisites; remove superseded Python orchestration and VM wrappers. Then narrow broad recovery scenarios while retaining real host and replacement witnesses.
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
