## Why

The current Gateway serves both public and private routes; the optional NGINX edge supplies the public-only filter. Homelab needs that boundary at the Gateway so a remote TCP entrance can carry public traffic without gaining access to private applications or management services.

## What Changes

- Reuse one declarative route inventory for separate public and private Gateway entries. Public entry permission remains independent of bootstrap readiness and the private network technology.
- Keep TLS termination, HTTP routing and authentication policy at the Gateway. A remote TCP relay carries encrypted connections and reports client addresses over an authenticated private link; it cannot reach private application or management endpoints.
- Accept transport metadata only on the relay's restricted receiving path. At the Gateway, discard client-supplied forwarding, end-user identity and request-ID headers, generate a fresh request identifier, and keep credentials out of logs.
- Require administrator routes to remain closed until identity provisioning succeeds and their SecurityPolicies are applied before their routes.
- Require generic TLS backends to verify chains against their declared trust source, while reserving strict canonical-hostname verification and public-PKI system roots for Kanidm.
- Define Kanidm's canonical identity hostname across direct and failover entrances, private interactive bootstrap, provisioning, and normal-operation transition without persisting bootstrap credentials outside that session.
- Pin the Gateway controller and data-plane to exact multi-architecture image identities, order Argo applications by their real prerequisites, and wait for child Application health before reporting readiness.
- Keep unique declared Application/object/source ownership. Separate rendered checks, disposable end-to-end proof and deployment acceptance; neither an actual public box nor production credentials are needed for the disposable proof.
- Record the retained Kanidm boundary and native export capability as non-operational future Preserve input; this change creates no capture schedule, retention, route, target, adapter, verification, or restore workflow.
- Keep application startup, configuration reconciliation, media storage, and state-protection policy outside this contract, following the stable `management-boundaries` ownership split.
- **BREAKING:** replace the optional NGINX HTTP-edge roles and their trusted-HTTP-proxy configuration with the transport-only entrance. Migrate their consumers and tests without retaining compatibility aliases.
- Do not select a provider, deploy an edge, change service exposure values, add bootstrap phases, or implement automatic home failover in this planning revision.

## Capabilities

### New Capabilities

- `service-exposure`: Durable service-route, trust-boundary, identity-bootstrap, and acceptance-evidence requirements for independently managed household services.

### Modified Capabilities

None.

## Impact

- Affects Gateway objects and route attachments, host and guest firewalls, backend admission, the TCP relay/private link, generated operations guidance and the affected route, policy and runtime checks.
- Build on PR #122's resolved route data rather than introducing a second route registry. Preserve the independent hardening and release-selection work in PRs #106 and #115.
- Retains the existing identity lifecycle, public-PKI trust, ownership and Preserve boundaries; no application-internal or state-protection work moves into this change.
- Real endpoint addresses, encrypted keys, production certificates and deployment approval are commissioning inputs, not prerequisites for preparing the configuration and disposable tests.
