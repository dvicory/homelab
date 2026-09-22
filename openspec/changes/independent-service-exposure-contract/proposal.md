## Why

Homelab needs one durable contract for exposing independently managed services without making application deployments own shared ingress or identity infrastructure. The existing route, trust, and bootstrap implementation can otherwise publish an administrator route before identity policy exists, or let independently reconciled entrances drift.

## What Changes

- Define one declarative route inventory for internal Gateway routes and optional independent public entrances. Each route declares one or more hostnames, its backend service, authentication mode, exposure class, backend TLS/trust declaration, and request-timeout policy; public-edge consumers validate any hostname cardinality or domain-family rules they require.
- Require public routes using administrator authentication to remain absent from every entrance until identity provisioning succeeds and the corresponding SecurityPolicy is published atomically with the route.
- Preserve independent public entrances while accepting forwarded client-address metadata only from configured proxy peers, discarding client-supplied forwarding, end-user identity, and request-ID metadata, propagating one trusted request identifier through both layers, and emitting queryless logs.
- Require generic TLS backends to verify chains against their declared trust source, while reserving strict canonical-hostname verification and public-PKI system roots for Kanidm.
- Define Kanidm's canonical identity hostname across direct and failover entrances, private interactive bootstrap, provisioning, and normal-operation transition without persisting bootstrap credentials outside that session.
- Pin the Gateway controller and data-plane to exact multi-architecture image identities, order Argo applications by their real prerequisites, and wait for child Application health before reporting readiness.
- Define unique declared Application ownership for every generated object identity and source directory, and keep structural checks separate from live two-layer request, DNS, certificate, authentication, logging, and failure-isolation evidence.
- Record the retained Kanidm boundary and native export capability as non-operational future Preserve input; this change creates no capture schedule, retention, route, target, adapter, verification, or restore workflow.
- Keep application startup, configuration reconciliation, media storage, and state-protection policy outside this contract, following the stable `management-boundaries` ownership split.

## Capabilities

### New Capabilities

- `service-exposure`: Durable service-route, trust-boundary, identity-bootstrap, and acceptance-evidence requirements for independently managed household services.

### Modified Capabilities

None.

## Impact

- Affects Den route and cluster schemas, Gateway API rendering, independent public-edge proxies, Kanidm integration, generated operations guidance, Argo convergence declarations, desired-state ownership checks, and contract checks.
- Composes with the existing `management-boundaries` independent-recovery requirement and the Preserve `first-class-state-protection` State/Realization/Integration model without taking ownership of either capability.
- Does not require a particular public provider, certificate issuer, application configuration mechanism, protection policy, or Preserve-owned backup cadence.
- Static evaluation proves declarations and rendered desired state only; live public routing, authentication, request-ID propagation, request logging, and failure isolation remain operator-gated acceptance work.
