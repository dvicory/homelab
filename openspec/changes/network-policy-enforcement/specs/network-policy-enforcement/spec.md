## Purpose

Keeps declared NetworkPolicies in force for every running Pod in the application-compute cluster, refuses rather than admits connections when enforcement fails, and makes any failure to enforce visible instead of silent.

## ADDED Requirements

### Requirement: Declared NetworkPolicies apply to every running Pod

Once the policy enforcer is ready, the application-compute cluster SHALL apply each declared NetworkPolicy to every running Pod the policy selects, including Pods that started after a guest restart, a host reboot or a guest replacement and received new addresses. A Pod's first connection after the enforcer is ready SHALL already be decided by policy. Enforcement SHALL NOT depend on restarting Pods after the cluster starts.

Each time the guest starts there is a window, from the first Pod start until the enforcer is ready, in which declared NetworkPolicies are not enforced. On a restarted guest the window lasts until the enforcer's own Pod is ready. On a new guest it also covers the delivery controller's bootstrap, whose seeded Pods start before the controller delivers the enforcer. The window SHALL end without operator action, and the post-reboot check SHALL show when it has ended.

#### Scenario: The guest restarts and every Pod gets a new address

- **WHEN** the compute guest restarts and its Pods come back with new addresses
- **THEN** each policy-selected Pod is protected by its NetworkPolicies at its new address, and a Pod that is not a declared caller is refused

#### Scenario: A Pod starts after the cluster settled

- **WHEN** a Pod starts in a running cluster and immediately opens a connection
- **THEN** that first connection is admitted or refused according to the declared policies, without any other Pod being restarted

#### Scenario: The guest starts

- **WHEN** the guest boots, restarts or is newly created and its Pods start before the enforcer is ready
- **THEN** declared NetworkPolicies are not enforced until the enforcer is ready, after which they apply to every running Pod without operator action

### Requirement: Enforcement fails closed when the enforcer fails

When the policy enforcer has failed while its enforcement is in place, new connections that policy would decide SHALL be refused, not admitted unchecked, until the enforcer recovers. The enforcer SHALL recover without operator action.

#### Scenario: The enforcer crashes

- **WHEN** the enforcer process is killed
- **THEN** new connections to and from policy-selected Pods, including a declared caller's, are refused until the enforcer is running again, a Pod that is not a declared caller is never admitted, and declared callers connect again once it is back

### Requirement: The enforcer does not depend on what it enforces

The policy enforcer SHALL start, and restart after a failure, without any connection that passes its own enforcement and without the delivery controller, so a failed enforcer cannot prevent its own recovery. The delivery controller SHALL deliver it, and wait for it to be ready, before every workload it delivers; only the delivery controller's own seeded Pods may start before it.

#### Scenario: The enforcer restarts while it is failing closed

- **WHEN** the enforcer is restarted while new Pod connections are being refused
- **THEN** it reaches its API and becomes ready without passing its own enforcement, and enforcement resumes

### Requirement: A failure to enforce NetworkPolicy is visible

The enforcer's health SHALL be reported to the delivery controller and to the operator's post-reboot check, and it SHALL expose its verdicts for monitoring. Acceptance testing on the production guest envelope SHALL fail when a declared boundary is not enforced. The platform SHALL NOT treat a cluster whose enforcer is failing as healthy merely because older rules remain in place.

#### Scenario: Enforcement is absent in acceptance testing

- **WHEN** the acceptance fixture runs without a working enforcer
- **THEN** a Pod that must be refused reaches its target and the acceptance check fails

#### Scenario: An operator checks enforcement after a reboot

- **WHEN** an operator follows the post-reboot runbook check after a host reboot, guest restart or guest replacement
- **THEN** the check shows whether the enforcer is ready and any failed firewall update since the guest started, and shows nothing amiss when enforcement is working

### Requirement: Enforcement capacity covers the node's Pod limit

Policy enforcement, and the node's other firewall updates, SHALL succeed with all declared NetworkPolicies and Services when the compute node runs as many Pods as its Pod limit admits, without depending on host-wide tuning beyond the kernel's defaults.

#### Scenario: The node is full

- **WHEN** the compute node runs Pods up to its Pod limit, with every additional Pod selected by a declared NetworkPolicy and behind a declared Service, on a host with the kernel's default socket buffers
- **THEN** every firewall update succeeds and every policy-selected Pod is protected
