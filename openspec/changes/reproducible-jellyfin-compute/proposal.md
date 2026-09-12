## Why

The current checkout enables Incus but does not declare a Kubernetes guest or a persistent Kubernetes workload. A recoverable Jellyfin slice will establish whether repository-controlled compute replacement works without relying on a surviving guest root, Kubernetes database, or undocumented bootstrap actions.

## What Changes

- Introduce a replaceable application-compute lifecycle with explicitly designated durable data, credentials, ownership mappings, and recovery inputs.
- Use an **unprivileged Incus system container**, as selected by the operator. Privileged containers, host-root identity mappings, and silent relaxation of isolation are not fallback paths.
- Use one independently deployable, shared NixOS compute guest running single-server K3s and its bundled Flannel/kube-proxy networking. Jellyfin is its first workload, not the owner of the guest lifecycle. Diverse applications may share the node; declared maintenance outages are acceptable.
- Build secret-free guest artifacts. Deliver guest identity through host-managed runtime secret materialization; keep all required bootstrap inputs available outside Kubernetes.
- Reconstruct Kubernetes resources from the shipped bootstrap and Argo handoff to canonical Git manifests. Deliver application images and manifests separately from the guest OS generation. Retain Jellyfin configuration separately from guest and cluster state; expose media through host bind mounts, read-only for this slice.
- Confine missing application storage to the dependent workload. Keep the node, its management path, and unrelated workloads available; prove storage loss and return without node replacement.
- Use standard NixOS/Incus/Kubernetes facilities first, established upstream tools second, and thin custom glue only for demonstrated gaps. NixOS owns Incus resource configuration; instance operations do not create a second configuration owner.
- Separate same-version compute recovery from application upgrades. Keep the application image independently pinned and require a consistent data recovery point with matching software before an application-version change.
- Provide inspectable, safely repeatable application-neutral instance operations and a separately authorized destructive replacement procedure. Use existing NixOS deployment commands and explicit application maintenance procedures; do not build a general-purpose orchestrator or workload-plugin framework.
- Add an x86_64 `prod-home-replacement` acceptance procedure that preserves real Jellyfin users, library configuration, and playback state across deletion and reconstruction of the guest and Kubernetes database.
- Preserve the accepted isolation decision recorded in ADR-0001.
- Keep host-local storage placement explicit for Jellyfin without imposing it on other applications. Additional physical hosts, portable storage, and control-plane availability are outside this slice; adding a node does not make local data portable.

No deployment is authorized by this plan. Local implementation evidence is distinct from target-runtime evidence; production inspection, credentials, deployment, and destructive operations remain separately authorized.

### Non-goals

No live Jellyfin migration; no physical storage migration or repartitioning; no changes to the legacy Hermes nspawn service; no public ingress, DNS changes, SSO, hardware acceleration, multi-node availability, distributed storage, or fleet-wide observability stack. Preserve the current lockfile unless a specific compatibility defect justifies a separately reviewed change. Retained same-host data is not a backup or protection against host loss.

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
- Focused local verification; target deployment and destructive-test acceptance on `hvn-hyp1` remain unexecuted and separately authorized.
