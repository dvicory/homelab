## 1. Contract and decision history

- [ ] 1.1 Record the disposable-control-plane proposal, storage delta, design, and ADR update, then verify `openspec validate --change disposable-control-plane-recovery` passes.
- [ ] 1.2 Revise overlapping `reliable-household-services` recovery/backup tasks so they no longer require the deleted packaged restore/resume path, then verify `openspec validate --change reliable-household-services` passes.

## 2. Remove obsolete recovery implementation

- [ ] 2.1 Delete `household-recovery`, its inventory/script, recovery freshness alerts, capture-check plumbing, offline Jellyfin fixtures, and sandbox artifacts, then verify no remaining references except historical decision records.
- [ ] 2.2 Narrow static bootstrap to the Argo namespace/CRDs/controllers, staged secrets, and explicit root-application handoff, then verify bootstrap manifests evaluate and the host wrapper rejects incomplete artifacts.

## 3. Replacement verification

- [ ] 3.1 Rewrite the Jellyfin VM scenario around online guest replacement, Argo seed/root handoff against a disposable Git origin, and real registry image pulls, then verify the test derivation evaluates and its offline/import behavior is gone.
- [ ] 3.2 Run canonical manifest freshness, GitOps source, Jellyfin contract, and affected evaluation checks successfully.
- [ ] 3.3 Regenerate and review operations declarations affected by the narrower recovery path.
