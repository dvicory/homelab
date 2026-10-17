## Context

See proposal.md for the production failure. This design records why K3s's embedded controller fails in this guest, what was measured, why the controller is replaced rather than given a bigger buffer, and how the replacement is delivered, fails, is observed and is migrated to.

The compute guest is an unprivileged Incus system container (ADR-0001) running single-node K3s with Flannel and kube-proxy in iptables mode. The guest's iptables uses the nf_tables backend.

### Why the embedded controller fails

On every sync, kube-router rebuilds the whole iptables filter table and loads it with one `iptables-restore --wait -T filter`. iptables-nft sends the table as one netlink batch in a single `sendmsg`. The kernel refuses a netlink message larger than the socket's send buffer minus 32 bytes with `EMSGSIZE` ("Message too long"). iptables-nft tries to enlarge the buffer only with `SO_SNDBUFFORCE`, which needs `CAP_NET_ADMIN` in the initial user namespace, and does not fall back to `SO_SNDBUF`. In the unprivileged guest that call fails, so the buffer stays at the host's `net.core.wmem_default`. Clusters where K3s runs as real root never see this.

### Evidence

From `checks.compute-network-policy-runtime` and exploratory variants of it, run on hvn-hyp1 as a build box. The fixture host uses hvn-hyp1's evaluated kernel (6.18.49), Incus envelope and sysctls, and creates the real `compute-1` guest with the production lifecycle helper. Stand-in Pods carry the pod labels of every committed workload; all 18 committed NetworkPolicies are applied.

- **Reproduction.** At the kernel default (212992 bytes) with 69 Pods, 38 `Aborting sync ... (sendmsg() failed: Message too long` lines within seven minutes; at 110 Pods, 96. Policy-selected Pods had no firewall chains.
- **The buffer iptables gets.** A netlink socket opened inside the guest's user and network namespaces starts at 212992 bytes; `SO_SNDBUFFORCE` returns `EPERM`. A host trace of a real sync shows `setsockopt(3, SOL_SOCKET, SO_SNDBUFFORCE, [2097152], 4) = -1 EPERM` and then `sendmsg(...) = -1 EMSGSIZE`.
- **Host-wide, not per guest.** Raising `net.core.wmem_default` on the fixture host gave new sockets in the guest the new size at once; the guest's `/proc/sys/net/core/wmem_default` reads the host's value.
- **Exact threshold.** With a 759252-byte batch, a buffer of batch + 32 bytes synced; batch + 31 failed.
- **Growth.** Each policy-selected Pod adds 16 rules and 10040 bytes, every other Pod 15 rules and 9380 bytes: about 640 bytes a rule. The fixed part, with all committed policies, is about 79 KB. The 212992-byte default is exceeded at about 14 Pods; at the 110-Pod limit the batch is 1170892 bytes.
- **No legacy fallback.** hvn-hyp1's kernel is built without `CONFIG_NETFILTER_XTABLES_LEGACY`; `ip_tables` and `iptable_filter` do not exist.

## Goals / Non-Goals

**Goals:**

- NetworkPolicy enforcement whose capacity does not depend on host-global tuning.
- A deliberate, tested failure mode, and health that Argo, operators and monitoring can see.
- A migration of the running guest with no unenforced window, and a rollback.

**Non-Goals:**

- A privileged guest, or anything that weakens ADR-0001.
- AdminNetworkPolicy, BaselineAdminNetworkPolicy or a cluster-wide default policy.
- Monitoring alerts; the monitoring change owns them (task 5.1).

## Decisions

### Replace kube-router's enforcement with kube-network-policies

kube-network-policies (kubernetes-sigs, the reference implementation), v1.1.2. Its nftables table holds only Pod address sets and a few fixed rules; each new connection's first packet goes to userspace through nfqueue, where policy is evaluated. Its firewall updates are small and do not grow with rules per Pod.

Prototype and check results in the same fixture, guest unprivileged, host at the kernel default buffer:

- It runs with no host change; its nftables table and nfqueue work.
- All representative probes (Kanidm's private policy, a Gateway backend policy, the media caller boundary, an unpoliced control) were correct with either failure mode, after a guest restart when every Pod had a new address, and for a new Pod's first connection.
- With logging at verbosity 2, a decision took 1.5–2.3 ms.

Alternatives considered:

- **Raise `net.core.wmem_default` on the host (first version of this change).** Rejected by the owner: it makes a security boundary depend on a host-global sysctl whose required value grows with the Pod and policy count, with no bound by design, and it changes the default for every socket on the host. A runtime value serves only as a stopgap until the migration.
- **Privileged guest, or `CAP_NET_ADMIN` on the host for K3s.** Rejected by ADR-0001.
- **Raise only `wmem_max`.** No effect: iptables-nft never calls `SO_SNDBUF`.
- **Legacy iptables backend.** Not available in hvn-hyp1's kernel.
- **Patch iptables to try `SO_SNDBUF` first.** Still bounded by a host-global sysctl and a carried patch.

### Deliver it as a platform component, before every workload Argo delivers

`kubernetes.services.network-policy` renders the upstream objects (ServiceAccount, ClusterRole with list/watch on Pods, Namespaces and NetworkPolicies, ClusterRoleBinding, DaemonSet) into a `network-policy` Argo Application in `kube-system`, sync wave -3, before Argo's own Application (-2). The image is pinned by digest and pulled from `registry.k8s.io`, like the other registry-delivered platform components. The DaemonSet uses the host network, tolerates every taint and runs at `system-node-critical` priority.

The container is not privileged. It holds only `NET_ADMIN` (every other capability dropped, no privilege escalation), which covers nftables, nfqueue and conntrack in the guest's network namespace; the NRI socket and `/var/run/netns` are host paths it reads as root. Upstream's manifest runs it privileged, but a privileged container would see every guest device, including the render node ADR-0010 delegates only to declared holders. The check confirms the enforcer works this way and cannot see or create the render node, while a privileged container in the same guest can open it.

The guest's K3s gets `--disable-network-policy` in the `services.kubernetes` aspect.

It does not depend on anything it enforces: on the host network it reaches the API server, the registry and the node's resolver without passing its own rules (it does not use cluster DNS), and the kubelet restarts it without Argo.

### Accept a start-up window

The enforcer is an ordinary Pod, so it cannot be ready before the node starts Pods. Each guest start therefore leaves a window in which declared policies are not enforced:

- On a restart or reboot, every Pod, the enforcer included, starts at once from local images; the window ends when the enforcer's Pod is ready. After a restart with 108 Pods, the check found 2 of the 88 policy-selected Pods already running when the enforcer became ready, the first for about one second (Kubernetes timestamps have one-second resolution).
- On a new guest, the bootstrap applies Argo's controllers and the root Application first (`modules/den/aspects/kubernetes/bootstrap.nix`). Argo's own Pods, which committed policies select, run unprotected until the root Application delivers the enforcer in wave -3, the image is pulled and the Pod is ready. Every later wave waits for it, so no other workload starts before it.

The spec states this window rather than promising enforcement from the first Pod. Closing it would mean holding every other Pod until the enforcer is ready, for example with a node taint the enforcer removes, or seeding the enforcer with the bootstrap before Argo. Neither is in this change; the window is visible through the DaemonSet's readiness, which the post-reboot check confirms.

### Fail closed

`--fail-open=false`. Evidence:

- With its rules installed and the process not reading the queue, new Pod connections are dropped. The check kills the enforcer twice (the second kill puts the kubelet into a 10-second back-off): a declared caller probing every half second was refused 6 times in the gap and admitted again afterwards (32 times), and a stranger was refused all 14 times.
- After a crash the kubelet restarted it in under five seconds.
- If its dataplane cannot open the queue after installing rules, traffic stops: the failure is loud, not silent.
- A graceful stop removes its rules in both modes, so traffic is open while it is absent after a DaemonSet deletion or during an update. Fail-open would add unchecked admission on every crash.

For a cluster whose admin applications have no login of their own and rely on the Gateway and NetworkPolicy, refusing during a crash is the safer failure. The cost: while the enforcer is down, every new Pod connection fails, including ones a policy would admit; the kubelet's restart bounds it.

### Visibility

- Argo: the Application is healthy only when the DaemonSet is ready; its readiness probe requires the metrics endpoint to answer. Every later sync wave waits for it.
- Metrics: `:9080/metrics` on the node (host network), with `kube_network_policies_packet_count{verdict}`, processing time and nfqueue drop counters. The guest firewall keeps it off the guest's external interface; the monitoring change decides how to scrape it (task 5.1).
- Logs: verbosity 0 (errors). Verbosity 2 logs every new connection's verdict with source and destination Pods; it is meant for investigating a denial, not for steady state.
- Limitation: the readiness probe proves the process serves metrics, not that its dataplane works; the verdict counters and the acceptance check cover that.

### Run kube-proxy in nftables mode

kube-proxy also writes iptables-nft tables with `iptables-restore` in the same guest, so its batches face the same limit. The check replays the live tables through the guest's own tools at the kernel default buffer, with all committed Services and every filler Pod behind the radarr Service:

| kube-proxy mode | Pods | nat or kube-proxy table | Result at 212992 bytes |
|---|---:|---:|---|
| iptables | 29 (committed workloads) | 88864 bytes | fits |
| iptables | 108 | 246112 bytes | `Message too long` |
| nftables | 108 | 110044 bytes | accepted |

In iptables mode a full rewrite of the nat table fails once enough endpoints exist, the same failure as kube-router's. nftables mode updates incrementally, and its `nft` client first raises its buffer with `SO_SNDBUF`, which an unprivileged process may do up to `net.core.wmem_max`; on hvn-hyp1's kernel that reads 4194304 with nothing in this repository setting it. The check traced `SO_SNDBUF, [2097152] = 0`, then `SO_SNDBUFFORCE ... = -1 EPERM`, and the whole table was accepted. kube-proxy cleans up the other mode's rules when it starts. The `services.kubernetes` aspect sets `mode = "nftables"`. The check confirms a ClusterIP Service between Pods and the household ingress NodePort from outside the guest work in both modes.

kube-proxy reads its mode only from its configuration file in the guest OS, so the mode changes when the guest runs the new bundle (guest replacement), not with the in-place migration below. Until then the production guest stays in iptables mode, where its nat table measured 88864 bytes at the committed workload count, under the 212992-byte default.

## Risks / Trade-offs

- [nfqueue puts a userspace process on the path of every new Pod connection.] → Fail-closed bounds the effect to the kubelet's restart time; verdict and queue-drop metrics show load.
- [A deliberate stop or update of the DaemonSet leaves Pods unprotected for seconds.] → Updates are rare and pinned; the runbook check confirms readiness afterwards.
- [Young project: v1.1.2 fixed an nfqueue packet-loss bug in September 2026.] → Pinned by digest; the check runs the committed manifests on the production envelope before any change ships.
- [The image comes from a registry at first start, as for other registry-delivered components.] → Until it is pulled, no rules exist, so nothing is blocked; workloads wait for it in a later wave.
- [The remaining plain-K3s VM checks (media-ingress-runtime and identity-provision-runtime) run their own K3s with kube-router and iptables kube-proxy.] → Task 4.2 tracks moving those checks. The superseded Gateway-only wrapper is covered by the required native Gateway scenarios using the committed enforcer; that parity does not close the separate start-up-window decision in task 4.3.
- [The in-place migration leaves a K3s config drop-in in the guest that is not declared in Nix.] → It only repeats the declared flag; guest replacement makes it redundant.

## Migration Plan

Host activation does not change the guest's OS: the guest's K3s flags and kube-proxy configuration come from the guest bundle at create or replace. The in-place migration below needs no guest replacement and keeps policy enforced throughout; the check runs these steps on a guest started with the pre-change K3s unit at 107 Pods, with a stranger and a declared caller probing radarr every half second. Over the 87 seconds of steps 2–4 the stranger was refused all 41 times and the caller admitted all 169 times; K3s left 1902 kube-router rules behind, and the cleanup removed them all.

1. Keep the runtime send-buffer stopgap on hvn-hyp1 so kube-router keeps syncing.
2. Merge. Argo syncs the `network-policy` Application (wave -3); wait until `kube-system/kube-network-policies` is ready. Both enforcers now apply; a connection must pass both.
3. In the guest, add the K3s config drop-in `/etc/rancher/k3s/config.yaml.d/50-disable-network-policy.yaml` containing `disable-network-policy: true` and restart K3s. Pods keep running (`KillMode=process`). kube-router stops, but its rules stay (k3s-io/k3s#7244).
4. Run the runbook's kube-router cleanup in the guest; it must report no rule left.
5. Run the post-reboot check. The stopgap is no longer needed and may lapse at the next reboot; kube-proxy stays in iptables mode, within the default buffer at the current workload count.
6. At the next guest replacement (`compute-guest replace` with the new bundle, then bootstrap), K3s gets the flag from the bundle, kube-proxy switches to nftables mode, and the drop-in becomes redundant.

Alternatively, replace the guest with the new bundle at once: its fresh network namespace has no kube-router rules, and Argo applies the enforcer before the workloads. This is a full guest replacement, with its downtime.

### Rollback

A rollback returns to kube-router, so it returns to the original defect: kube-router syncs only while the host's runtime send-buffer stopgap is set, and the stopgap lapses at every reboot. In every case, keep the enforcer deployed until kube-router is confirmed to be syncing, so a rollback never leaves the cluster with neither.

- Before step 3: revert the change in Git. Argo removes the enforcer; its graceful stop removes its rules. kube-router has been enforcing throughout.
- After step 3 or 4:
  1. Set the stopgap on the host if it has lapsed (`sysctl -w net.core.wmem_default=4194304`, runtime only).
  2. In the guest, delete `/etc/rancher/k3s/config.yaml.d/50-disable-network-policy.yaml` and restart K3s.
  3. Confirm kube-router is syncing: the guest's K3s journal since the restart has no `Aborting sync`, and `iptables-save` shows `KUBE-ROUTER-FORWARD` rules for the current Pod addresses.
  4. Revert the change in Git. Argo removes the enforcer.
- After a guest replacement with the new bundle:
  1. Set the stopgap on the host.
  2. Replace the guest with the previous bundle and bootstrap it. K3s runs kube-router again and kube-proxy starts in iptables mode, removing its nftables rules. Argo still delivers the enforcer from Git, so both enforce.
  3. Confirm kube-router is syncing, as above.
  4. Revert the change in Git. Argo removes the enforcer.


## Open Questions

None.
