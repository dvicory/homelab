## Why

Homelab needs one durable contract for exposing independently managed services without making application deployments own shared ingress or identity infrastructure. The current implementation has route, trust, and bootstrap behavior, but those guarantees are not stated by any current capability spec.

## What Changes

- Define one declarative route inventory as the source for internal Gateway routes and optional independent public entrances.
- Require each route to declare its hostnames, exposure, backend trust, and request timeouts.
- Preserve independent public entrances while accepting forwarded client identity only from configured proxy peers.
- Keep shared ingress and identity infrastructure operational when an unrelated routed application is unavailable.
- Define canonical identity bootstrap and normal-operation phases without persisting bootstrap credentials outside the private interactive recovery session.
- Expose Kanidm's durable-state and native-export facts as a future integration input to Preserve's `first-class-state-protection` model without defining policy, routes, lifecycle-owner wiring, schedules, retention, or recovery here.
- Separate structural configuration evidence from live end-to-end acceptance evidence.
- Keep application startup, configuration reconciliation, media storage, and state-protection policy outside this contract.

## Capabilities

### New Capabilities

- `service-exposure`: Durable service-route, trust-boundary, identity-bootstrap, and acceptance-evidence requirements for independently managed household services.

### Modified Capabilities

None.

## Impact

- Affects Den route and cluster schemas, Gateway API rendering, independent public-edge proxies, Kanidm integration, generated operations guidance, and contract checks.
- Composes with the existing `management-boundaries` independent-recovery requirement and the Preserve `first-class-state-protection` State/Realization/Integration model without taking ownership of either capability.
- Does not require a particular public provider, certificate issuer, application configuration mechanism, protection policy, or backup cadence.
- Live public routing, authentication, request logging, and failure isolation remain operator-gated acceptance work rather than claims made from static evaluation.
