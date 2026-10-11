## Context

See proposal.md for the production failure. This design records why it happens, what was measured, the fix chosen, and the evaluation of a replacement enforcer.

The compute guest is an unprivileged Incus system container (ADR-0001) running single-node K3s with Flannel and K3s's embedded network-policy controller (kube-router). The guest's iptables uses the nf_tables backend.

### Mechanism

On every sync the controller rebuilds the whole iptables filter table and loads it with one `iptables-restore --wait -T filter`. iptables-nft sends the table as one netlink batch in a single `sendmsg`. The kernel refuses a netlink message larger than the socket's send buffer minus 32 bytes with `EMSGSIZE` ("Message too long"). iptables-nft tries to enlarge the buffer only with `SO_SNDBUFFORCE`, which needs `CAP_NET_ADMIN` in the initial user namespace; it does not fall back to `SO_SNDBUF`. In the unprivileged guest that call fails, so the buffer stays at the host's `net.core.wmem_default`. `net.core.wmem_max` plays no part.

Clusters where K3s runs as real root never see this: `SO_SNDBUFFORCE` succeeds there.

### Evidence

All from `checks.compute-network-policy-runtime` and an exploratory variant of it, run on hvn-hyp1 as a build box. The fixture host uses hvn-hyp1's evaluated kernel (6.18.49), Incus envelope and sysctls, and creates the real `compute-1` guest with the production lifecycle helper. Stand-in Pods carry the pod labels of every committed workload; all 18 committed NetworkPolicies are applied.

- **Reproduction.** Default buffer (212992 bytes), 69 Pods, 50 of them policy-selected: 38 `Aborting sync. Failed to run iptables-restore ... (sendmsg() failed: Message too long` lines within seven minutes, and policy-selected Pods without firewall chains.
- **The buffer iptables gets.** A netlink socket opened inside the guest's user and network namespaces starts at 212992 bytes; `SO_SNDBUFFORCE` returns `EPERM` and the size stays 212992. A host trace of a real controller sync shows the same call: `setsockopt(3, SOL_SOCKET, SO_SNDBUFFORCE, [2097152], 4) = -1 EPERM`.
- **Host-wide, not per guest.** Raising `net.core.wmem_default` on the fixture host to 16 MiB gave new sockets inside the guest 16 MiB at once, and the guest's `/proc/sys/net/core/wmem_default` read the host's value. On this kernel the value is global; a guest cannot have its own.
- **Exact threshold.** With a 759252-byte batch, `wmem_default` = batch + 32 synced; batch + 31 failed with `EMSGSIZE`.
- **Growth.** Measured with a large buffer so every sync succeeded:

  | Pods | Policy-selected | Filter rules | Batch (bytes) |
  |---:|---:|---:|---:|
  | 29 | 10 | 542 | 357652 |
  | 39 | 20 | 702 | 458052 |
  | 49 | 30 | 862 | 558452 |
  | 69 | 50 | 1182 | 759252 |
  | 89 | 50 | 1482 | 946852 |
  | 110 (Pod limit) | 91 | 1838 | 1170892 |

  Each policy-selected Pod adds 16 rules and 10040 bytes; each other Pod adds 15 rules and 9380 bytes (about 640 bytes a rule). The fixed part, with all committed policies and K3s's own chains, is about 79 KB. The 212992-byte default is exceeded at about 14 Pods, so the production cluster fails on every sync.
- **Worst case.** The kubelet admits at most 110 Pods. At that limit the batch measured 1170892 bytes; with every Pod policy-selected it would be about 1.18 MB.
- **Recovery without restart.** After the host value was raised, the next sync of the running K3s succeeded; neither K3s nor the guest was restarted.

## Goals / Non-Goals

**Goals:**

- Restore enforcement with a bounded, declarative change, sized for the worst case the node admits.
- Make enforcement failure fail acceptance testing, and give operators a post-reboot check.
- Decide, with evidence, whether to replace the embedded controller.

**Non-Goals:**

- A privileged guest, or any change that weakens ADR-0001.
- Alerting from a monitoring stack; none is deployed yet.

## Decisions

### Raise the host's default send buffer to 4 MiB

`modules/den/aspects/virtualization/compute.nix` declares `net.core.wmem_default = 4194304` on hosts that run the compute guest. 4 MiB is 3.5 times the 1.18 MB worst case, so the node cannot reach the limit by adding Pods, and about 3 MB remain for more policies. It equals the `wmem_max` hvn-hyp1 already runs with.

Alternatives considered:

- **Privileged guest, or `CAP_NET_ADMIN` on the host for K3s.** Rejected by ADR-0001.
- **A per-guest value.** Not possible: on this kernel `net.core.wmem_default` is host-wide.
- **Raise only `wmem_max`.** No effect: iptables-nft never calls `SO_SNDBUF`. hvn-hyp1 already has 4 MiB there and still fails.
- **Legacy iptables backend.** Legacy iptables replaces a table with one `setsockopt` and has no netlink batch limit, but hvn-hyp1's kernel is built without `CONFIG_NETFILTER_XTABLES_LEGACY`, so `ip_tables` and `iptable_filter` do not exist. Using it would need a custom kernel, and K3s and kube-proxy would also have to be forced onto the legacy backend. Rejected.
- **Patch iptables to try `SO_SNDBUF` first**, as upstream `nft` did in 2023. Possible, but it carries a patch on K3s's iptables and still needs `wmem_max` sized; the sysctl is simpler.
- **Replace the controller now.** See the evaluation below.

### Make failure loud in tests and in operations

`checks.compute-network-policy-runtime` fills the node to its Pod limit with Pods that committed policies select, on the production guest envelope and host sysctls. On first boot and after a guest restart it fails if K3s's journal has a failed sync, if a policy-selected Pod lacks its chain at its current address, if a representative boundary (Kanidm's private policy, a Gateway backend policy, the media caller boundary) is not enforced, or if the traced batch does not fit the guest's buffer. It also fails if the batch is not larger than 212992 bytes, so the fixture cannot silently shrink below the old failure point. Without the sysctl the check fails on first boot.

The runbook check in `docs/operations.md` greps the guest's K3s journal for the controller's failure messages after a host reboot, guest restart or replacement. A monitoring alert on the same pattern is a task for when monitoring exists.

### Keep K3s's controller for now; revisit kube-network-policies on specific triggers

kube-network-policies v1.1.2 (kubernetes-sigs, reference implementation) was prototyped in the same fixture: K3s with `disable-network-policy`, the upstream DaemonSet with the image imported locally, host buffer left at 212992 bytes, 69 Pods.

Results:

- It ran in the unprivileged guest with no host change; its nftables table and nfqueue worked.
- All ten representative probes were correct with `--fail-open=true` and `--fail-open=false`, after a guest restart when every Pod had a new address, and for a newly created Pod's first connection.
- K3s's journal had no iptables-restore failure at the 212992-byte default: its nftables table holds Pod address sets, not per-Pod rules, so it has no batch-size problem.
- With logging at `--v=2`, each new connection's decision is logged with source and destination Pod names; a decision took 1.5–2.3 ms.
- **Failure mode.** With the enforcer deliberately stopped, traffic was open in both modes: fail-open leaves its rules with queue bypass, and fail-closed removes its rules on graceful shutdown. Fail-closed only drops traffic while its rules exist without a listener, such as a crash. After `SIGKILL` the kubelet restarted it before the first probe (under five seconds), so no drop window was observed.

Benefits: per-connection visibility and metrics; a selectable failure mode; AdminNetworkPolicy and BaselineAdminNetworkPolicy for a cluster-wide baseline (not tested here); no full-table rewrites, so no buffer dependency; upgrades independent of K3s releases.

Costs: every new connection to or from a Pod waits on a userspace process (nfqueue), so the enforcer is on the data path; one more pinned component to deliver, upgrade and monitor; a young project (v1.1.2 fixed an nfqueue packet-loss bug in September 2026); a stopped enforcer opens everything in either mode, so "fail-closed" needs its own guard.

Recommendation: do not replace the embedded controller in this change. The buffer fix is bounded and proven, and the new check will catch a recurrence. Reconsider kube-network-policies when one of these becomes true: Homelab wants a cluster-wide baseline policy (BaselineAdminNetworkPolicy); the embedded controller fails in a way the buffer does not cover, or K3s changes or drops it; kube-network-policies has a longer stable record. Before adopting it: pin and deliver it like other platform components, declare `disable-network-policy` in the kubernetes aspect, decide the failure mode and add a guard for a stopped enforcer, lower log verbosity, add its metrics to monitoring, and run this check against it.

## Risks / Trade-offs

- [A host-wide default affects every new socket on the host, not just the guest's netlink sockets.] → It is a ceiling, not an allocation: memory is charged only for data actually queued. TCP sizes its buffers from `tcp_wmem` and is unaffected. UDP, Unix datagram and netlink senders can queue up to 4 MiB before blocking; hvn-hyp1 has ample memory.
- [Policies grow faster than expected.] → The check measures the batch at the Pod limit on every run, and fails before production does if it no longer fits.
- [The prod-home-replacement and compute-guest-upgrade fixtures do not copy this sysctl.] → They copy only the bridge sysctls and do not assert policy sync. A task tracks bringing them in line.
- [K3s's controller still freezes rules on any other sync failure.] → The new check and the runbook surface it; replacement triggers are listed above.

## Migration Plan

1. Activate the new host configuration on hvn-hyp1. No guest or K3s restart is needed; the next controller sync (on the next Pod or policy change, or the periodic resync) succeeds.
2. Run the runbook check in `docs/operations.md` for the time since activation; it must print nothing. Confirm that the Kanidm and media app Pods have chains at their current addresses.

Rollback: revert the sysctl and activate. Syncs then fail again as before; nothing else changes.

## Open Questions

None.
