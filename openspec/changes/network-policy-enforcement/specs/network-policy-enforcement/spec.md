## Purpose

Keeps declared NetworkPolicies in force for every running Pod in the application-compute cluster, and makes any failure to enforce them visible instead of silent.

## ADDED Requirements

### Requirement: Declared NetworkPolicies apply to every running Pod

The application-compute cluster SHALL apply each declared NetworkPolicy to every running Pod the policy selects, including Pods started after a guest restart, a host reboot or a guest replacement, when Pods receive new addresses. Enforcement SHALL NOT depend on restarting Pods after the cluster starts.

#### Scenario: The guest restarts and every Pod gets a new address

- **WHEN** the compute guest restarts and its Pods come back with new addresses
- **THEN** each policy-selected Pod is protected by its NetworkPolicies at its new address, and a Pod that is not a declared caller is refused

#### Scenario: A Pod starts after the cluster settled

- **WHEN** a Pod that a declared NetworkPolicy selects starts in a running cluster
- **THEN** the policy applies to that Pod without any other Pod being restarted

### Requirement: A failure to enforce NetworkPolicy is visible

When the policy enforcer cannot apply the current NetworkPolicies, the failure SHALL be visible to the operator's post-reboot check, and acceptance testing on the production guest envelope SHALL fail. The platform SHALL NOT treat a cluster whose enforcer is failing as healthy merely because older rules remain in place.

#### Scenario: The enforcer fails to apply policy in acceptance testing

- **WHEN** the policy enforcer reports a failed policy update, or a policy-selected Pod has no rules at its current address, in the acceptance fixture
- **THEN** the acceptance check fails and reports the enforcer's error and the affected Pods

#### Scenario: An operator checks enforcement after a reboot

- **WHEN** an operator follows the post-reboot runbook check after a host reboot, guest restart or guest replacement
- **THEN** the check shows any enforcer failure since the guest started, and shows nothing when enforcement is working

### Requirement: Enforcement capacity covers the node's Pod limit

Policy enforcement SHALL succeed with all declared NetworkPolicies when the compute node runs as many Pods as its Pod limit admits. A capacity limit of the enforcement mechanism SHALL be sized against that bound, with recorded margin, rather than against the current Pod count.

#### Scenario: The node is full

- **WHEN** the compute node runs Pods up to its Pod limit, with every additional Pod selected by a declared NetworkPolicy
- **THEN** every policy update succeeds and every policy-selected Pod is protected
