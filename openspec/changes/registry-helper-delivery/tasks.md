## 1. Publisher capability

- [x] 1.1 Inventory the current four helper producers and every consumer/preload; verify each exact producer, native platform, and secret-free packaged input before defining publication identities.
- [x] 1.2 Implement publication from exact Nix outputs and record source, archive, manifest, config/rootfs, and platform identities; verify the command publishes an exact built artifact to a real disposable TLS registry and refuses an incompatible artifact before selection.
- [x] 1.3 Implement separate anonymous verification of an already-published candidate; verify public consumer access, declared producer/config/rootfs identity, verified TLS, and native platform identity without publisher credentials.
- [x] 1.4 Implement automatic publication only from an exact same-repository merged-main push after the complete required-CI gate, using a separate main-owned publisher with scoped package-write permission and no per-release approval click. Verify exact source/tooling SHA, run and attempt; refusal of PR, manual, fork, incomplete-CI and altered-artifact sources; fixed destinations; and read-only producer execution. Keep production consumers unchanged in the publisher PR.

## 2. Changed-path integration proof

- [x] 2.1 Exercise the publish/verify/select path with a real existing helper and a genuinely different compiled A/B release; prove meaningful Kubernetes Job behavior, unchanged guest/control-plane identity and usable retained state, no helper preload/import or guest recreation, and owned cleanup.
- [x] 2.2 Preserve positive listener/availability controls and prove wrong or missing digest, untrusted TLS, wrong architecture, and producer mismatch refusal; retain sanitized native failure evidence and do not replace these cases with manifest-string checks.
- [x] 2.3 Update existing operations guidance with automatic main-only publication after required CI versus separately gated selection, public visibility, supported rollback, and registry-only rebuild/availability limits; verify commands against the exercised interface.

## 3. Authorized real publication

- [x] 3.1 Record the owner's approval for automatic merged-main publication after required CI, the four public GHCR namespaces, irreversible visibility, and scoped package permission; obtain separate approval before merging the publisher PR.
- [x] 3.2 After the reviewed publisher PR is merged, publish the exact native helper artifacts through the main-owned workflow; verify their real manifest/config/platform identities and that every required executor has succeeded for that exact source and attempt.
- [x] 3.3 Configure the approved public visibility through GitHub's supported interface and verify anonymous access to each exact digest; produce verified candidate identities and refuse private, missing, wrong-platform, altered, or mismatched releases.

## 4. Clean consumer cutover and acceptance

- [x] 4.1 Select the actual verified digests for all four helper consumers and migrate affected fixtures; verify generated resources use only the selected identities and that producer input file sets cannot create a digest-lock/source cycle.
- [x] 4.2 Remove the corresponding helper preloads, obsolete Never-only pull policy and routine manual staging paths; verify unrelated K3s platform airgap inputs and runtime secret ownership are unchanged, with no empty-lock fallback or dual-mode resolver.
- [x] 4.3 Regenerate tracked outputs and run the existing freshness, schema, security and relevant consumer contracts once after edits; smoke the final changed application path, preserving meaningful cases from later fleet changes.
- [ ] 4.4 Open the consumer cutover PR with exact publication evidence and operator gates; after separate owner merge/rollout approval, observe application reconciliation without helper import, host activation or guest replacement and record retained identity/state and explicit rollback acceptance.
