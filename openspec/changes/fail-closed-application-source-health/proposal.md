## Why

A real-controller test showed that an Application with a missing Git directory reports `ComparisonError` and `Healthy`, allowing its parent's later sync wave to run. Parent rollout gates must not treat an unavailable desired-state source as a healthy prerequisite.

## What Changes

- **BREAKING**: Explicit child source/comparison errors block later parent sync waves even when the child's workload health remains Healthy.
- Restore ordinary health propagation when the error clears; prove that reconciliation resumes without a manual bypass.
- Preserve existing missing-health behavior and distinguish OutOfSync from a source error.
- Keep this production-semantic change separate from the meaningful-verification tooling migration.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `management-boundaries`: Parent deployment sequencing must fail closed on an explicit child source/comparison error, with recovery after the error clears.

## Impact

Changes the existing Argo Application health customization, its generated ConfigMap, relevant operator documentation and behavioral checks. No new controller, dependency, deployment domain or general dependency engine. The health rule does not stop existing workloads or gate independently reconciling child Applications. Git outages can pause later parent waves, including unrelated applications in those waves. Implementation and PR review are authorized; merge and deployment remain operator-controlled.
