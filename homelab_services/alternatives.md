# Alternatives and recommendations

## Guest OS lifecycle

### A. Secret-free image, then closure deployment over SSH — recommended

Flow:

1. Build a NixOS rootfs tar image from a pinned flake output.
2. Import it under `/var/lib/machines/<node>` with `machinectl import-tar` or an equivalently verified import unit.
3. Before first boot, a host-side root-only provisioner copies the guest SSH host/age identity from `/run/agenix` into the guest's persistent state.
4. Boot, validate SSH host identity, and deploy the current guest NixOS closure over SSH.
5. Perform routine upgrades with a deploy-rs/nixos-rebuild-style closure copy and activation. Preserve generations and test rollback.
6. Use image re-import only for disaster recovery or deliberate replacement.

Why: guest OS upgrades are independent from `hvn-hyp1`; closure activation and rollback remain normal NixOS operations; the image is reproducible and safe to cache.

Security correction to the initial idea: do **not** place a plaintext SSH/age private key in a Nix derivation or reusable image tar. Nix store paths and build products are not secret storage. If an artifact containing the key is ever necessary, assemble it outside the Nix store in a root-only, non-cached host unit and destroy it immediately after import. Runtime first-boot injection is safer and simpler.

### B. Re-import for every upgrade

Pros: strongly image-oriented; replacement behavior is exercised often.  
Cons: awkward state attachment, longer outage, more bootstrapping risk, and unnecessary churn. Reject for routine upgrades; keep as the recovery path.

### C. Remote rebuild from source on the guest

Pros: fewer deployment outputs.  
Cons: guest requires source credentials and build capacity; activation depends on external inputs; rollback provenance is less controlled. Reject as the primary path. The guest may build locally as a break-glass option.

## Nspawn versus VM

### Nspawn — accepted with an explicit threat model

Pros: low overhead; shared page cache/kernel; direct DRM device exposure; easy host dataset binds; useful learning without another hypervisor layer.  
Cons: K3s/containerd requires broad cgroup, namespace, mount, networking, and possibly BPF access. The guest shares the host kernel and is not a hostile-workload boundary.

Contract: cluster-admin or container escape must be treated as potential host-root compromise. Do not schedule untrusted code. A phase-zero spike must prove cgroup v2, overlayfs, containerd, networking, reboot, and GPU behavior.

### VM

Pros: clearer kernel/security boundary; K3s and CNI paths are conventional; easier future migration to another physical node.  
Cons: extra memory/storage overhead and less convenient host filesystem/device integration.

Fallback trigger: use a VM if the nspawn proof requires writable host-global `/sys`, fragile cgroup workarounds, or unsafe device/BPF exposure beyond the accepted model.

## Kubernetes distribution and networking

### K3s with conservative built-ins — recommended baseline

Start with K3s server, embedded SQLite initially or embedded etcd only if a tested snapshot/restore requirement justifies it, CoreDNS, Flannel, kube-proxy, and local-path provisioning. Disable components only when their replacement is ready.

For ingress, use one of:

- initial smoke phase: bundled Traefik;
- target phase: Envoy Gateway and Gateway API, using K3s ServiceLB/host ports for the single node.

The target Envoy choice aligns with Sini's OIDC `SecurityPolicy` pattern. It does not require adopting Cilium.

### Cilium first

Pros: Sini parity, excellent network policy and observability, future BGP/L2/Gateway options.  
Cons: BPF/cgroup/device requirements inside nspawn and a larger bootstrap blast radius.

Defer until the baseline cluster and restore path work. Adopt later only if its policy/observability value exceeds nested-kernel complexity.

## GitOps

### Nixidy + Argo CD — recommended

Pros:

- closest to Sini and this repository's den/aspect model;
- Nix-typed/reusable application configuration;
- explicit application graph, health, sync waves, diffs, and UI;
- good learning value;
- clean separation: Nix renders desired state, Argo reconciles it.

Costs: CRD/type-generation bootstrap, generated-manifest workflow, several Argo components, and careful secret post-processing. Use an external Git remote initially; do not make cluster recovery depend on a Git server hosted inside the failed cluster.

### Flux

Pros: smaller pull-oriented operational surface, idempotent bootstrap, self-management, strong Helm/Kustomize primitives, built-in image automation.  
Cons: no first-party full UI and less direct reuse of Sini's Nixidy/Argo patterns.

Fallback trigger: choose Flux if the Nixidy/Argo proof cannot produce deterministic manifests and a one-command bootstrap without excessive custom machinery.

### Manual Helm or direct apply

Useful only for the phase-zero application smoke test. Reject as steady state because it weakens reproducibility, review, and disaster recovery.

## Kubernetes storage

### Host ZFS + guest local PV + host NFS — recommended

- Guest/K3s state and local PVC data live on dedicated host ZFS datasets attached to stable guest paths.
- Bulk/personal datasets remain host-owned and enter Kubernetes through static NFS PVs with `Retain` and GitOps prune protection.
- Application-aware backups leave the cluster before host snapshots/off-site upload.

This preserves storage ownership, avoids a single-node distributed-storage facade, and resembles Sini's NAS boundary.

### Bind every dataset directly into the guest and use hostPath

Fast and simple but tightly couples pod manifests to node paths, bypasses useful PV ownership boundaries, and makes accidental host access easier. Use binds only for guest system/local-PV state and devices, not as the general application storage API.

### Separate NAS VM/guest

Cleaner administrative boundary but introduces a second OS lifecycle in the physical disk path and complicates recovery without providing HA. Reconsider only if the chosen NAS software requires appliance ownership of disks.

### Longhorn/Rook/Ceph

Reject for one physical host. Replicas would share the same failure domain while adding recovery and write-amplification complexity.

## Bulk media storage

### mergerfs + SnapRAID — recommended for replaceable media

Appropriate for large, mostly immutable files and heterogeneous incremental expansion. Individual data disks remain readable. SnapRAID parity is asynchronous: files added since the last sync are unprotected, and changes/deletions can reduce recovery of a failed disk. Therefore:

- use dedicated parity disks at least as large as the largest data disk;
- select parity count only after disk-count/failure-domain analysis (dual parity is the conservative default for a large pool);
- retain multiple content-file copies outside the affected pool;
- coordinate imports/deletions with sync, and alert on failed/stale sync;
- scrub on a measured schedule;
- never describe parity as backup.

### ZFS for all media

Provides real-time checksums, snapshots, redundancy, and simpler correctness semantics. Expansion constraints and disk-layout economics are less flexible, though modern OpenZFS expansion options should be evaluated against the actual future hardware.

Use ZFS instead if the disk inventory becomes homogeneous, media churn is high, or operational simplicity outweighs incremental expansion.

### Current gocryptfs backing layout

Do not automatically extend it. Before SnapRAID design, decide whether per-disk LUKS should replace gocryptfs. SnapRAID needs an explicit protected view and deletion workflow; layering parity over encrypted backing trees changes names/churn and recovery ergonomics. The roadmap includes a disposable-data proof before migration.

## Personal data storage

Use a separate ZFS pool or independently fault-tolerant vdev/dataset hierarchy. Do not place irreplaceable photos/files on the mergerfs/SnapRAID tier merely because it has free space. Required properties:

- checksummed redundant storage;
- dataset-level snapshots and quotas;
- separate datasets for Immich originals, user homes/shares, application state, and backup staging;
- encrypted off-site copies;
- restore tests at file, dataset, and application levels.

Exact mirror/RAIDZ topology waits for disk and growth inventory.

## NAS access stack

### Host Samba + restricted NFS — recommended base

- SMB is the primary user-facing LAN protocol for macOS/Windows/Linux.
- NFS is an infrastructure protocol for the K3s guest and trusted Linux clients.
- Neither protocol is exposed directly to the internet.
- Stable Unix IDs/ACLs are defined once on the host; Kubernetes services receive only the identities and paths they need.

This is a NAS without an appliance UI. NixOS is the control plane, ZFS/mergerfs are the storage layer, and Samba/NFS are access frontends.

### Document sync/share frontend

Recommendation: evaluate Nextcloud first because it supplies mature web/mobile sync, sharing, user spaces, and OIDC integration. Keep it a frontend over a dedicated personal-data dataset, not the filesystem authority for Immich originals or media libraries.

Alternatives:

- Seafile: efficient sync but stores data in an application-managed object/block format, weakening direct filesystem recovery expectations.
- Syncthing: excellent device-to-device replication, but not a full multi-user browser/share/NAS frontend.
- plain WebDAV: simple protocol but weaker household account, sharing, and mobile-product experience.

Final choice is deferred to a hands-on client and restore evaluation.

## Identity placement

### Kanidm on host edge plane — recommended

Matches Sini: identity remains available independently of K3s reconciliation, can authenticate Kubernetes/Argo and applications, and uses this repository's existing deterministic IDs/group concepts. It does couple Kanidm upgrades to `hvn-hyp1`, but its data is small and strongly backed up.

Every critical system retains a documented local break-glass credential. OIDC outage must not block host recovery, guest SSH, `machinectl shell`, or K3s local-admin kubeconfig use.

### Kanidm inside K3s

Reduces host services but creates identity/bootstrap and recovery cycles. Reject for the first architecture.

## Secrets

### Host bootstrap, independent cluster key — recommended

- Host agenix owns the guest machine SSH/age identity and the initial cluster SOPS age key.
- First boot copies machine identity into persistent guest state and creates the SOPS operator key Secret.
- Application secrets are encrypted in Git for the cluster key and reconciled in-cluster.
- Kanidm/client pairs derive from one encrypted source when both sides must share a value.
- Recovery operators keep an offline-encrypted copy of the identities needed to reconstruct host and cluster.

This mirrors Sini while avoiding continuous ad hoc secret copying from host into pods.

### Vault/external secrets immediately

Useful at larger scale but creates another recovery-critical stateful system. Defer until there is a concrete rotation/dynamic-credential requirement.
