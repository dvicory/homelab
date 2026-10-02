The platform cut implements the bootstrap boundary. The Jellyfin cut's
`prod-home-replacement` scenario supplies the target-runtime evidence for
section 2; it is hosted-CI VM evidence, not a production deployment.

## 1. Remove obsolete recovery implementation

- [x] 1.1 Delete `household-recovery`, its inventory/script, obsolete recovery
  freshness alerts, capture-check plumbing, offline fixtures, and sandbox
  artifacts.
- [x] 1.2 Narrow static bootstrap to the Argo namespace/CRDs/controllers,
  staged Secrets, and explicit root-Application handoff; verify that the host
  wrapper rejects incomplete artifacts.

## 2. Replacement boundary

- [x] 2.1 Keep the later workload cut's target-runtime replacement scenario
  outside this platform change. It must invoke the shipped bootstrap boundary,
  use a test-local root Application against a disposable Git origin, and
  verify its own application state. `prod-home-replacement` lives in the
  Jellyfin cut, runs the shipped `household-bootstrap-host`, seeds the
  `recovery-test-apps` root Application against a `git daemon` origin on the
  compute bridge, and verifies Jellyfin's retained state after replacement.
- [x] 2.2 On an appropriate Linux runner, exercise the platform's bootstrap
  and reconciliation handoff with the tracked-source contract. Record local
  evaluation separately from target-runtime evidence; no workload acceptance is
  implied by this task. Hosted CI `checks (x86_64-linux)` runs
  `prod-home-replacement`, whose phases `static-bootstrap-and-root-handoff-without-git`,
  `first-git-reconciliation` and
  `second-bootstrap-registry-pulls-and-argo-reconciliation` cover the handoff
  on a fresh and a replaced guest.
- [x] 2.3 Regenerate and review the operations declaration after the bootstrap
  and tracked-ref wording settles. `docs/operations.md` is generated, and
  `diff-files` keeps it identical to the evaluated configuration.
