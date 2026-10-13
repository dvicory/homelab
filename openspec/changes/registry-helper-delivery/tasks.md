## 1. Publisher capability

- [ ] 1.1 Inventory the current four helper producers and every consumer/preload; verify each exact producer, native platform, and secret-free packaged input before defining publication identities.
- [x] 1.2 Implement publication from exact Nix outputs and record source, archive, manifest, config/rootfs, and platform identities; verify the command publishes an exact built artifact to a real disposable TLS registry and refuses an incompatible artifact before selection.
- [x] 1.3 Implement separate anonymous verification of an already-published candidate; verify public consumer access, declared producer/config/rootfs identity, verified TLS, and native platform identity without publisher credentials.
- [x] 1.4 Add early read-only PR builds and a separate main-owned publisher with scoped package-write permission; verify approved same-repository source/SHA and fixed package destinations, refusal of forks/unauthorized sources and altered artifacts, and no execution of PR code with publication credentials. Keep production consumers unchanged in the publisher PR.

## 2. Changed-path integration proof

- [x] 2.1 Exercise the publish/verify/select path with a real existing helper and a genuinely different compiled A/B release; prove meaningful Kubernetes Job behavior, unchanged guest/control-plane identity and usable retained state, no helper preload/import or guest recreation, and owned cleanup.
- [x] 2.2 Preserve positive listener/availability controls and prove wrong or missing digest, untrusted TLS, wrong architecture, and producer mismatch refusal; retain sanitized native failure evidence and do not replace these cases with manifest-string checks.
- [x] 2.3 Update existing operations guidance with early publication versus gated selection, public visibility, supported rollback, and registry-only rebuild/availability limits; verify commands against the exercised interface.

## 3. Authorized real publication

- [ ] 3.1 Record the owner's approval for early trust-separated publication, the four public GHCR namespaces, irreversible visibility, and scoped package permission; obtain separate approval before merging the publisher PR.
- [ ] 3.2 After the reviewed publisher PR is merged, publish the exact native helper artifacts through the main-owned workflow; verify their real manifest/config/platform identities and that no unrelated test dependency delays the build/publication lane.
- [ ] 3.3 Configure the approved public visibility through GitHub's supported interface and verify anonymous access to each exact digest; produce verified candidate identities and refuse private, missing, wrong-platform, altered, or mismatched releases.

## 4. Clean consumer cutover and acceptance

- [ ] 4.1 Select the actual verified digests for all four helper consumers and migrate affected fixtures; verify generated resources use only the selected identities and that producer input file sets cannot create a digest-lock/source cycle.
- [ ] 4.2 Remove the corresponding helper preloads, obsolete Never-only pull policy and routine manual staging paths; verify unrelated K3s platform airgap inputs and runtime secret ownership are unchanged, with no empty-lock fallback or dual-mode resolver.
- [ ] 4.3 Regenerate tracked outputs and run the existing freshness, schema, security and relevant consumer contracts once after edits; smoke the final changed application path, preserving meaningful cases from later fleet changes.
- [ ] 4.4 Open the consumer cutover PR with exact publication evidence and operator gates; after separate owner merge/rollout approval, observe application reconciliation without helper import, host activation or guest replacement and record retained identity/state and explicit rollback acceptance.
