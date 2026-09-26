The platform bootstrap boundary is implemented locally. Target-runtime
replacement and application acceptance are owned by later workload cuts and
are not claimed here.

## 1. Remove obsolete recovery implementation

- [x] 1.1 Delete `household-recovery`, its inventory/script, obsolete recovery
  freshness alerts, capture-check plumbing, offline fixtures, and sandbox
  artifacts.
- [x] 1.2 Narrow static bootstrap to the Argo namespace/CRDs/controllers,
  staged Secrets, and explicit root-Application handoff; verify that the host
  wrapper rejects incomplete artifacts.

## 2. Replacement boundary

- [ ] 2.1 Keep the later workload cut's target-runtime replacement scenario
  outside this platform change. It must invoke the shipped bootstrap boundary,
  use a test-local root Application against a disposable Git origin, and
  verify its own application state.
- [ ] 2.2 On an appropriate Linux runner, exercise the platform's bootstrap
  and reconciliation handoff with the tracked-source contract. Record local
  evaluation separately from target-runtime evidence; no workload acceptance is
  implied by this task.
- [ ] 2.3 Regenerate and review the operations declaration after the bootstrap
  and tracked-ref wording settles.
