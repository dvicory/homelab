## Why

The current checkout enables Incus but does not declare a Kubernetes guest or a persistent Kubernetes workload. A recoverable Jellyfin slice will establish whether repository-controlled compute replacement works without relying on a surviving guest root, Kubernetes database, or undocumented bootstrap actions.

## What Changes

- Introduce a replaceable application-compute lifecycle with explicitly designated durable data, credentials, ownership mappings, and recovery inputs.
- Use an **unprivileged Incus system container**, as selected by the operator. Privileged containers, host-root identity mappings, and silent relaxation of isolation are not fallback paths.
- Use one independently deployable NixOS guest running single-server K3s, its bundled Flannel/kube-proxy networking, and a new private Jellyfin instance. These are the reviewed mechanisms for this slice, not permanent fleet-wide selections; Cilium is not assumed compatible with the user-namespace boundary.
- Build secret-free guest artifacts. Deliver guest identity through host-managed runtime secret materialization; keep all required bootstrap inputs available outside Kubernetes.
- Reconstruct Kubernetes resources from stable Nix-generated manifests using native K3s reconciliation. Retain Jellyfin configuration separately from guest and cluster state; expose media through host bind mounts, read-only for this slice.
- Confine missing application storage to the dependent workload. Keep the node, its management path, and unrelated workloads available; prove storage loss and return without node replacement.
- Use standard NixOS/Incus/Kubernetes facilities first, established upstream tools second, and thin custom glue only for demonstrated gaps. NixOS owns Incus resource configuration; instance operations do not create a second configuration owner.
- Separate same-version compute recovery from application upgrades. Keep the application image independently pinned and require a consistent data recovery point with matching software before an application-version change.
- Provide inspectable, safely repeatable instance operations and a separately authorized destructive replacement procedure without building a general-purpose orchestrator.
- Add an acceptance procedure that preserves real Jellyfin users, library configuration, and playback state across deletion and reconstruction of the guest and Kubernetes database.
- Preserve the accepted isolation decision in its ADR; keep implementation choices in this change rather than introducing a duplicate architecture/status document.

No deployment is authorized now. Local implementation verification and future target-runtime verification must be reported separately.

### Non-goals

No live Jellyfin migration; no physical storage migration or repartitioning; no changes to the legacy Hermes nspawn service; no public ingress, DNS changes, SSO, hardware acceleration, multi-node availability, distributed storage, GitOps controller, or fleet-wide observability stack. Preserve the current lockfile unless a specific compatibility defect justifies a separately reviewed change. Retained same-host data is not a backup or protection against host loss.

## Capabilities

### New Capabilities

- `compute-recovery`: The isolation, durable-input, storage-attachment, application failure-domain, safe-update, lifecycle, and recovery-verification contracts of a replaceable application-compute domain.

### Modified Capabilities

None. The new capability specializes, without changing, the existing `management-boundaries`, `storage-foundations`, `secret-management`, and `access-control` contracts.

## Impact

- `hvn-hyp1`: a Den compute-host aspect supplying Nix attrsets to native Incus preseed, plus private network enforcement, narrow storage exports, runtime identity delivery, and bounded instance operations. Application-media availability does not gate the whole node. No physical NIC bridge conversion or routine destructive storage initialization.
- New Den guest entity and reusable guest/platform aspects; host metadata stays in entities and behavior in aspects.
- Nix-generated Kubernetes namespace, static retained volumes/claims, Jellyfin deployment/service, and a pinned workload image available as a reproducible build input.
- Workstation-accessible build, lifecycle, status, and recovery commands; no essential dependency on a source checkout on the deployment host.
- Focused local verification plus an explicit later deployment and destructive-test gate on `hvn-hyp1`.
- Historical `initial-k8s` and `mpkkqksmmwrl` work informs review only. Do not merge their unrelated changes, secret artifacts, old package pins, or unverified runtime assumptions wholesale.
