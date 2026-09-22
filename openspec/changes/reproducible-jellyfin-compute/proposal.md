## Why

The platform needs replaceable application compute that does not depend on a
surviving guest root, Kubernetes database, or undocumented bootstrap action.
The compute boundary must remain useful before any application workload is
selected.

## What Changes

- Introduce a replaceable application-compute lifecycle with explicitly
  designated durable inputs, credentials, ownership mappings, and recovery
  inputs.
- Use an **unprivileged Incus system container**, as selected by the operator.
  Privileged containers, host-root identity mappings, and silent relaxation of
  isolation are not fallback paths.
- Use one independently deployable, shared NixOS compute guest running
  single-server K3s with its bundled Flannel/kube-proxy networking. Diverse
  applications may share the node; declared maintenance outages are
  acceptable.
- Build secret-free guest artifacts. Deliver guest identity through
  host-managed runtime secret materialization; keep required bootstrap inputs
  available outside Kubernetes.
- Reconstruct platform resources from the shipped bootstrap and Argo handoff to
  tracked Git manifests. Deliver the guest OS and application releases as
  separate artifacts; workload-specific manifests and retained state belong to
  later workload cuts.
- Confine missing application storage to its dependent workload. Keep the
  node, its management path, and unrelated workloads available.
- Use standard NixOS/Incus/Kubernetes facilities first, established upstream
  tools second, and thin custom glue only for demonstrated gaps. NixOS owns
  Incus resource configuration; instance operations do not create a second
  configuration owner.
- Provide inspectable, safely repeatable application-neutral instance
  operations and a separately authorized destructive replacement procedure.
  Use existing NixOS deployment commands; do not build a general-purpose
  orchestrator or workload-plugin framework.
- Preserve the accepted isolation decision recorded in ADR-0001.

No deployment is authorized by this plan. Local implementation evidence is
distinct from target-runtime evidence; production inspection, credentials,
deployment, destructive operations, and workload acceptance remain separately
authorized and belong to the relevant later cut.

### Non-goals

No application workload or public ingress is selected here. This change does
not define DNS, SSO, hardware acceleration, multi-node availability,
distributed storage, physical storage migration, a backup engine, a backup
schedule, a retention policy, or a restoration destination. It also does not
change the legacy Hermes nspawn service or the current lockfile without a
separately reviewed compatibility defect.

## Capabilities

### New Capabilities

- `compute-recovery`: the isolation, durable-input, storage-attachment,
  application failure-domain, lifecycle, and recovery-boundary contracts of a
  replaceable application-compute domain.

### Modified Capabilities

None. The new capability specializes, without changing, the existing
`management-boundaries`, `storage-foundations`, `secret-management`, and
`access-control` contracts.

## Impact

- `hvn-hyp1`: a Den compute-host aspect supplying Nix attrsets to native Incus
  preseed, private network enforcement, narrow storage exports, runtime
  identity delivery, and bounded instance operations. Application-only storage
  does not gate the whole node.
- A Den guest entity and reusable guest/platform aspects; host metadata stays
  in entities and behavior in aspects.
- Secret-free guest artifacts, canonical platform manifests, and the runtime
  lifecycle commands needed to create, inspect, and explicitly replace the
  guest.
- Focused local verification; target deployment, destructive replacement, and
  application-runtime acceptance remain unexecuted and separately authorized.
