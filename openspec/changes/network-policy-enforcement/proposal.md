## Why

On hvn-hyp1, K3s's embedded network-policy controller (kube-router) in the unprivileged `compute-1` guest failed every sync, in this boot and the one before, with `Aborting sync ... iptables-restore ... Message too long`. The firewall stayed as it was at the last good sync, so Pods started since then, including every Pod after a restart, ran without their NetworkPolicies. This caused an outage after a host reboot (the Gateway proxy's new address was refused by Kanidm until Pods were restarted), and it left the media caller boundary from PR #58 unenforced. Nothing reported the failure except the K3s journal.

The controller cannot work reliably in this guest by design: it rewrites the whole filter table as one netlink batch whose size grows with every Pod, and the unprivileged guest cannot size the socket buffer for it. A runtime host sysctl keeps it working until this change deploys.

## What Changes

- **BREAKING**: K3s in the compute guest runs without its embedded network-policy controller. kube-network-policies, pinned by digest and delivered by Argo before every workload Argo delivers, enforces NetworkPolicy instead. Each guest start leaves a short window before the enforcer is ready; on a new guest it includes Argo's own bootstrap.
- kube-proxy runs in nftables mode: in iptables mode its nat table hits the same buffer limit at the node's Pod limit.
- The enforcer fails closed: when it has failed while its rules are installed, new Pod connections are refused instead of admitted unchecked.
- Enforcer health is visible to Argo and to an operator check, and it exposes verdict metrics for the monitoring work to scrape.
- A one-time migration for the running guest, with a minimal unenforced window, and a rollback.
- A VM acceptance check, on the production guest envelope and the node's Pod limit, covering the migration, enforcement before and after a guest restart, a new Pod's first connection, a crash of the enforcer, and kube-proxy's headroom.
- The runbook's post-reboot check covers the new enforcer and kube-proxy.

## Capabilities

### New Capabilities

- `network-policy-enforcement`: Declared NetworkPolicies apply to every running Pod in the compute cluster, including after restarts; enforcement fails closed when the enforcer fails; it starts without depending on what it enforces; failure is visible and fails acceptance; capacity covers the node's Pod limit.

### Modified Capabilities

None.

## Impact

- Guest OS: the compute guest's K3s gets `--disable-network-policy` and kube-proxy `mode: nftables`. The running guest needs a one-time migration for the enforcer; kube-proxy's mode changes at the next guest replacement (design.md, Migration Plan).
- Platform manifests: a new `network-policy` Argo Application in `kube-system`, sync wave -3.
- New check `checks.compute-network-policy-runtime` (x86_64, KVM, registry access).
- `docs/operations.md`: post-reboot check and the kube-router cleanup.
- The runtime `net.core.wmem_default` stopgap on hvn-hyp1 is no longer needed once the migration is done; nothing in this change depends on it.

Non-goals: making the guest privileged (ADR-0001); raising the host's socket buffer in configuration; changing the CNI; AdminNetworkPolicy or a cluster-wide baseline policy; monitoring alerts (tracked for the monitoring change).
