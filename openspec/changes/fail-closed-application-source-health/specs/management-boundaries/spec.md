## ADDED Requirements

### Requirement: Parent rollout gates fail closed on child source errors

When a parent deployment sequences later work using a child application's health, an explicit child source or desired-state comparison error SHALL prevent that child from satisfying the parent's healthy-prerequisite gate, even if existing workloads remain healthy. Once the error clears, the gate SHALL again use the child's ordinary health and SHALL permit normal reconciliation to resume without a health-rule bypass when its other prerequisites are satisfied.

A difference between desired and observed state alone SHALL NOT be treated as a source error. This gate SHALL NOT itself stop existing workloads, delete resources or prevent independently managed child reconciliation.

#### Scenario: Source error conflicts with healthy workloads
- **WHEN** a child reports that its desired-state source cannot be loaded or compared while its workload health remains healthy
- **THEN** the parent does not advance to work gated on that child's healthy status
- **AND** evaluating this gate does not stop the child's existing workloads

#### Scenario: The source error clears
- **WHEN** reconciliation clears the child's source error and the child is healthy with the parent's other prerequisites satisfied
- **THEN** the parent can advance through normal reconciliation without a manual health-rule bypass

#### Scenario: Healthy application has unapplied desired changes
- **WHEN** a healthy child's desired and observed state differ without a source or comparison error
- **THEN** that difference alone does not cause this source-error gate to report the child as unhealthy
