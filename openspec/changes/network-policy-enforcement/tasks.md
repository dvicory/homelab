## 1. Bounded buffer fix

- [x] 1.1 Declare `net.core.wmem_default = 4194304` in the compute aspect's host configuration, with the reason and the measured bound; verify `nix eval .#nixosConfigurations.hvn-hyp1.config.boot.kernel.sysctl."net.core.wmem_default"` prints 4194304.

## 2. Failure is visible

- [x] 2.1 Add `checks.compute-network-policy-runtime`: production guest envelope and host sysctls, committed policies and stand-ins, filler to the Pod limit; fail on a failed sync, a missing chain, a broken representative boundary or a batch that does not fit, on first boot and after a guest restart. Verify it passes with 1.1 and fails on first boot without it.
- [x] 2.2 Add the post-reboot check to `docs/operations.md`, matching the same failure messages as 2.1; verify the run of 2.1 without 1.1 reports matching K3s journal lines.
- [ ] 2.3 Copy the host's `net.core.*` sysctls into the prod-home-replacement and compute-guest-upgrade fixtures; verify both checks still pass.
- [ ] 2.4 When the monitoring stack exists, alert on the controller's failure messages in the guest's K3s journal; verify the alert fires in a fixture without 1.1.

## 3. Deployment

- [ ] 3.1 Activate the host configuration on hvn-hyp1; verify `sysctl net.core.wmem_default` prints 4194304.
- [ ] 3.2 Run the runbook check for the time since activation; verify it prints nothing and that the Kanidm and media app Pods have firewall chains at their current addresses.

## 4. Enforcer replacement

- [ ] 4.1 Re-evaluate kube-network-policies when a trigger in design.md ("Keep K3s's controller for now") occurs; verify by rerunning the prototype against `checks.compute-network-policy-runtime` and recording the result in a new change.
