## Context

See proposal.md for the problem and scope. Current producers supply four Nix-built Kubernetes helpers: retained-directories, Kanidm provision, Jellyfin provisioner, and Jellarr. Their credential values are runtime-mounted inputs, not producer arguments. Hermes is a separate runtime workload, not part of this helper cutover.

The historical `independent-application-delivery` proposal also covered guest OS activation. Keep that proposal and its completed disposable registry/activation receipts intact; neither grants publication or production cutover permission here. Current `management-boundaries` remains authority until the proposed delta is accepted.

This cross-cutting migration changes artifact trust, publication ordering, and consumer identities, so a design is required.

## Goals / Non-Goals

**Goals:** Reuse existing Nix producers and OCI tools; build candidates early, publish through a separate trusted boundary, verify exact identities before GitOps selects them, and remove routine helper imports and guest-closure coupling after acceptance.

**Non-Goals:** Guest OS activation, a self-hosted registry, GitHub Releases or a second archive store, an automatic deployment updater, application-internal changes, secret-owner changes, implicit replacement, a permanent old/new delivery resolver, or broader multi-architecture support than the declared fleet and tested producers require.

## Decisions

### Public GHCR with trust-separated early publication

Use `ghcr.io/dvicory/homelab/{retained-directories,kanidm-provision,jellyfin-provisioner,jellarr}`. Keep publication separate from Nix evaluation and Argo reconciliation. Build the existing Nix image producers in a read-only PR job that starts alongside other CI, not after unrelated runtime tests.

A separate publisher runs fixed workflow/tooling from main. It accepts only artifacts bound to an approved same-repository maintainer PR and source SHA, verifies the permitted package names and artifact/platform identity, and treats artifacts as data: it does not check out or execute PR scripts with publication credentials. Forks and unauthorized sources cannot publish. Do not use `pull_request_target` to execute PR code or trust artifact-provided workflow commands, paths, or destination names.

The publication job needs `packages: write`, not release-asset or repository write authority. Use an ephemeral authentication file with cleanup. No production credential values are build or publication inputs. The owner approved this publication boundary and the four public namespaces; each PR merge remains a separate gate.

GHCR packages start private. Authenticated push success is not consumer-access proof. The owner approved making exactly these namespaces public; for a personal account this cannot later be reversed to private. Complete visibility configuration through GitHub's supported interface, then verify anonymous consumer-equivalent access with verified TLS before selecting a digest.

### Publish, verify, then select

1. Resolve and build the producer from the permitted source. Audit its complete packaged content, allowing public certificate PEMs but refusing private-key material and production credential inputs.
2. Publish the exact native-platform artifact. Record the locked source/producer identity, archive checksum, remote manifest digest, config/rootfs identity, OS, and architecture. Preserve original config/rootfs identity when transport format changes.
3. Verify an already-published candidate without publisher credentials. Compare its retrieved identity with the declared producer output and verify anonymous digest access, TLS, and target platform. A receipt alone is not proof.
4. Only verified identities may enter committed desired state after required tests, review, and separately approved merge. A private, unavailable, wrong-platform, or mismatched artifact is ineligible. Keep selected identities outside producer input file sets to prevent a lock/source hash cycle.

Publication can finish while unrelated tests are still running. An unused candidate cannot update production: no mutable production tag is changed and no automatic selection commit is made. There is no mutable-tag or empty-lock fallback.

### Registry-only retention

Keep selected and supported rollback manifests and their referenced layers in GHCR. Do not add automatic package pruning. CI artifacts may transfer a build to the publisher but are not the retained release store.

Preserve the Nix producers, locked inputs, and committed digest mappings. If GHCR loses a version, rebuilding depends on those sources and inputs still being available; this design does not guarantee reproducing an exact digest or recovering during a GitHub-wide outage. GitHub Releases would add a second store and write permission without provider independence, so they are excluded.

### Two PRs, one final delivery mode

Land the complete publisher and verification capability first with production consumers unchanged. After authorized real publication and anonymous access verification, make one clean cutover of all four helper consumers to committed digests and remove their preload and `Never`-only/manual staging coupling. Keep unrelated K3s platform airgap inputs.

Do not merge an empty selected-release lock or conditional old-image resolver to simulate completion. The final implementation has one normal delivery mode. Unavailable selected images remain visible failures rather than silently substituting another release.

## Risks / Trade-offs

- **Public visibility is irreversible:** audit before publication and configure only the four approved namespaces.
- **Registry deletion or GitHub outage:** no independent archive is promised; preserve sources and locked identities, retain selected/rollback registry versions, and document the rebuild/access limit.
- **Wrong artifact or platform:** verify archive, config/rootfs, manifest identity, source recipe, and native target before selection; fail closed on mismatch.
- **Publisher privilege:** main-owned code, approved source checks, scoped package permission, no PR-code execution with write authority, bounded diagnostics, and credential-file cleanup.
- **Artifact succeeds but CI or consumer merge fails:** the candidate remains unused; publication does not bypass deployment gates.
- **New secret or helper behavior still needs its own integration:** registry delivery does not migrate runtime secret ownership or change application semantics.

## Migration Plan

1. Apply the owner-approved registry-only plan and early trust-separated publication boundary. Keep guest activation separately unapproved.
2. Review and separately approve the publisher capability PR merge so the trusted main-owned workflow exists before live CI publication.
3. Publish the helper candidates, configure the approved public visibility, and verify anonymous digest access and exact producer/platform identity.
4. Prove the publisher/verify/select path in a disposable TLS registry, including a genuinely different helper A/B update, meaningful Job behavior, wrong/missing identity and TLS refusal, no helper import or guest recreation, and owned cleanup. Historical same-image receipts are context, not this proof. Prove unauthorized publication requests are refused by trusted publisher code.
5. Open the consumer cutover PR with actual verified identities and all affected callers/fixtures migrated. Each PR merge and live rollout remains separately owner-approved.
6. On rollout, retain node/control-plane identity and usable state; keep old verified registry versions for explicit rollback. Missing pulls remain visible failures, not fallback behavior.

## Sources

- https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry
- https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility#configuring-visibility-of-packages-for-your-personal-account
- https://kubernetes.io/docs/concepts/containers/images/
