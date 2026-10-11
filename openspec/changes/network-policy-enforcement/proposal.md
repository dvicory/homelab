## Why

On hvn-hyp1, K3s's network-policy controller in the unprivileged `compute-1` guest has failed every sync, in this boot and the one before, with `Aborting sync ... iptables-restore ... Message too long`. The firewall stays as it was at the last good sync, so Pods started since then, including every Pod after a restart, run without their NetworkPolicies. This caused an outage after a host reboot (the Gateway proxy's new address was refused by Kanidm until Pods were restarted), and it means the media caller boundary from PR #58 is not enforced now. Nothing reported the failure except the K3s journal.

## What Changes

- Give the guest's iptables a send buffer that fits its policy table at the node's Pod limit, by declaring the host's default socket send buffer in the compute host configuration. The guest stays unprivileged.
- Add a VM acceptance check, on the production guest envelope, that fails when the policy controller reports a failed sync or leaves a policy-selected Pod without its rules, on first boot and after a guest restart. The fixture fills the node to its Pod limit, well past the old buffer size.
- Add a post-reboot operator check to the operations runbook.
- Record the evaluation of kube-network-policies as a replacement for K3s's embedded controller, with prototype results, and a recommendation on whether and when to replace it. This change does not replace the controller.

## Capabilities

### New Capabilities

- `network-policy-enforcement`: Declared NetworkPolicies apply to every running Pod in the compute cluster, including after restarts; failure to apply them is visible and fails acceptance; enforcement capacity covers the node's Pod limit.

### Modified Capabilities

None.

## Impact

- `modules/den/aspects/virtualization/compute.nix`: one host sysctl, `net.core.wmem_default`, on hosts that run the compute guest. It changes the default send buffer for every new socket on that host.
- New check `checks.compute-network-policy-runtime` (x86_64, KVM).
- `docs/operations.md`: post-reboot check.
- Deployment needs host activation on hvn-hyp1; the next controller sync then succeeds without a guest or K3s restart.

Non-goals: making the guest privileged (ADR-0001); changing the CNI; replacing K3s's network-policy controller in this change; alerting from the monitoring stack, which does not exist yet.
