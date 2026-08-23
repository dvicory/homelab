# management-boundaries Specification

## Purpose
Define ownership boundaries between managed machines, shared Homelab infrastructure, and independently developed workloads so that integration responsibilities and recovery dependencies remain explicit.

## Requirements

### Requirement: Homelab owns system integration without implicitly owning application internals

Homelab SHALL own the declarative configuration of managed machines and shared infrastructure. For an independently developed workload, Homelab SHALL own the workload's integration with that infrastructure, including the integration concerns that apply to it such as placement, persistence interfaces, runtime identity and secret delivery, networking and exposure, and deployment integration.

Application-internal behavior and configuration SHALL remain outside Homelab's authority unless ownership is explicitly transferred. Integrating a workload into Homelab SHALL NOT by itself make its internal application design a Homelab contract.

#### Scenario: An independently developed workload is deployed
- **WHEN** Homelab deploys a workload whose application is maintained in another repository
- **THEN** Homelab defines the system-facing integration needed to run it without duplicating the workload's internal application contract

### Requirement: Shared infrastructure dependencies may have Homelab operational contracts

When a workload or service is required for broader Homelab operation, Homelab MAY define the availability, recovery, security, or integration properties that the wider system requires from that dependency without taking ownership of its internal implementation.

#### Scenario: A centralized identity service becomes shared infrastructure
- **WHEN** multiple managed systems depend on an identity service maintained as a separate application
- **THEN** Homelab may specify the recovery and integration properties required of that service while Homelab's contract remains limited to those system-facing properties

### Requirement: A deployment domain retains an independent recovery path

A deployment or management domain SHALL have a recovery path that does not depend exclusively on services running inside the same domain being recovered.

A service MAY run inside a domain that normally depends on it, provided an independent break-glass, bootstrap, or lower-layer recovery path remains available.

#### Scenario: An application-compute domain is unavailable
- **WHEN** the services inside an application-compute domain cannot run
- **THEN** an operator can still reach the management boundary needed to repair, replace, or restore that domain without first restoring those same services

#### Scenario: Centralized identity is unavailable
- **WHEN** centralized identity cannot authenticate normal administrative access
- **THEN** the managed substrate retains an independent recovery path rather than requiring the failed identity service to recover itself
