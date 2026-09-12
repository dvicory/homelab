
## 2. Remove obsolete recovery implementation

- [x] 2.1 Delete `household-recovery`, its inventory/script, recovery freshness alerts, capture-check plumbing, offline Jellyfin fixtures, and sandbox artifacts.
- [x] 2.2 Narrow static bootstrap to the Argo namespace/CRDs/controllers, staged secrets, and explicit root-application handoff, then verify bootstrap manifests evaluate and the host wrapper rejects incomplete artifacts.

## 3. Replacement verification

- [ ] 3.1 Keep the x86_64 `prod-home-replacement` acceptance in `modules/tests/prod-home-replacement.{nix,py}`: invoke the shipped `household-bootstrap-host`, use its test-local root Application against a disposable Git origin, and pull pinned registry images. Keep Jellyfin-only HTTP behavior in `modules/tests/jellyfin_smoke.py`; evaluation or a different test does not close this runtime gate.
- [ ] 3.2 On an appropriate x86_64 Linux runner, run `prod-home-manifests-fresh`, `prod-home-gitops-source`, `den-semantics`, `compute-contracts`, `idmap-fixtures`, `mergerfs-capability`, `retained-storage-contracts`, `media-contracts`, `jellyfin-contracts`, `storage-roots-contracts`, and `prod-home-replacement`; record phase timings and leave this gate open until the replacement run succeeds.
- [x] 3.3 Regenerate and review operations declarations affected by the narrower recovery path.
