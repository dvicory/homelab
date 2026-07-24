# Homelab services architecture package

Status: **proposal for review; no implementation or OpenSpec work has started**  
Date: 2026-07-23

This untracked directory records the research, decisions, roadmap, risks, and open questions for a recoverability-first homelab platform on `hvn-hyp1`.

## Documents

1. [`requirements.md`](requirements.md) — agreed goals, non-goals, constraints, and acceptance targets.
2. [`research-sini.md`](research-sini.md) — relevant patterns in `~/src/den-examples/sini`, plus differences that prevent a direct copy.
3. [`architecture.md`](architecture.md) — recommended target architecture, data tiers, service placement, networking, secrets, backups, and recovery.
4. [`alternatives.md`](alternatives.md) — lifecycle, GitOps, storage, ingress, identity, and NAS alternatives with recommendations.
5. [`roadmap.md`](roadmap.md) — phased delivery plan and decision/acceptance gates. This is deliberately not an OpenSpec breakdown.
6. [`phase0-collection.md`](phase0-collection.md) — safe dual-host inventory collection commands, coverage, privacy, and follow-up workflow.
7. [`open-questions.md`](open-questions.md) — information and decisions still needed before implementation specs.
8. [`sources.md`](sources.md) — repository evidence and external primary documentation.

## Executive decision

Use `hvn-hyp1` as the **storage and edge plane**, and run application workloads in one independently deployed NixOS `systemd-nspawn` machine containing single-node K3s.

- Host: disk encryption/unlock, ZFS, mergerfs/SnapRAID, snapshots, backup jobs, NFS/SMB exports, public TLS edge, Kanidm, and Tailscale.
- Guest: K3s, GitOps controllers, databases, Jellyfin, Radarr, Sonarr, Immich, and later optional application frontends.
- Bulk storage crosses the boundary over tightly scoped NFS. User file access uses SMB. Kubernetes local state uses dedicated host-backed guest state/local-PV datasets.
- The guest OS is bootstrapped from a **secret-free** image, then receives its persistent SSH/age identity from host agenix before first boot. Plaintext identity material must never enter a Nix derivation, binary cache, or reusable image tarball.
- Future guest OS deployments and rollbacks happen over SSH and do not require rebuilding or switching `hvn-hyp1`.
- Nixidy-rendered manifests plus Argo CD are the proposed application delivery path because they align with Sini and provide useful GitOps visibility. Flux remains the simpler fallback.

## Deliberate boundaries

This proposal does not yet choose disk count/layout, a document-sync application, public DNS names, or exact backup software. Those choices depend on inventory and restore experiments in the roadmap. It does choose the responsibility boundaries and data protection model that those implementations must satisfy.
