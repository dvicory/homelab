## 1. Replace the enforcer

- [x] 1.1 Add `--disable-network-policy` to the guest's K3s in the `services.kubernetes` aspect; verify `nix eval .#nixosConfigurations.compute-1.config.systemd.services.k3s.serviceConfig.ExecStart` contains it.
- [x] 1.2 Add `kubernetes.services.network-policy`: kube-network-policies v1.1.2 pinned by digest, host network, fail-closed, metrics on :9080 with a readiness probe, sync wave -3; include it in `prod-home`; verify the regenerated manifests show `Application-network-policy.yaml` at wave -3 and `prod-home-manifests-fresh` passes.
- [x] 1.3 Run the enforcer unprivileged with only `NET_ADMIN`; verify `jellyfin-contracts` passes with its no-privileged-container rule and `compute-network-policy-runtime` shows the enforcer's only capability is `NET_ADMIN` and it cannot reach a hotplugged render node.

## 2. Acceptance

- [x] 2.1 Rework `checks.compute-network-policy-runtime`: production guest envelope with the send buffer pinned to and checked at the kernel's 212992-byte default, committed policies and Services, filler to the Pod limit; the migration from kube-router with a refused Pod probing throughout; after it and after a guest restart, the representative probes, a new Pod's first connection, a ready enforcer whose metrics count verdicts, no kube-router rule, no failed restore, kube-proxy's tables within the kernel default buffer; a crash of the enforcer refuses new connections until it is back. Verify it passes.
- [x] 2.2 Verify the counterfactual: without the enforcer the check fails because the stranger reaches radarr.

## 3. kube-proxy

- [x] 3.1 Record kube-proxy's restore failures and table sizes in the check, at the kernel default buffer, with all committed Services and the filler behind a Service; verify they appear in the check's evidence.
- [x] 3.2 Decide kube-proxy's mode from the measured headroom: in iptables mode the nat table is 88864 bytes at the committed workload count but 246112 bytes at 108 Pods, over the 212992-byte default; in nftables mode the whole table is 110044 bytes at 108 Pods and accepted. Switch to nftables mode; verify the check's `restarted` phase asserts nftables mode, ClusterIP and NodePort forwarding, and the table within the default buffers.

## 4. Operations

- [x] 4.1 Rewrite the runbook's post-reboot check for the new enforcer and kube-proxy, and add the kube-router cleanup from `_kube-router-cleanup.sh`, the same file the check runs; verify `files/docs/operations.md` passes.
- [ ] 4.2 Move gateway-runtime, media-ingress-runtime and identity-provision-runtime from K3s's embedded controller to the committed enforcer; verify each still passes.
- [ ] 4.3 Decide whether to close the start-up window in design.md ("Accept a start-up window"), for example with a node taint the enforcer removes or by seeding the enforcer before Argo; verify with a check that probes a policy-selected Pod from its first start.
- [ ] 4.4 Migrate hvn-hyp1 in the order of design.md (Migration Plan); verify the enforcer is ready, the cleanup leaves no kube-router rule and the post-reboot check is clean.

## 5. Monitoring

- [ ] 5.1 In the monitoring change (#54), scrape the enforcer's metrics, alert when the DaemonSet is not ready, when `kube_network_policies_nfqueue_*_dropped` grows and when K3s's journal reports a failed iptables restore; verify each alert fires in a fixture.
