---
id: ADR-0003
status: accepted
date: 2026-09-07
updated: 2026-09-07
decision-makers: [Homelab operator through delegated implementation authority]
consulted: []
informed: [Homelab operator]
supersedes: []
superseded-by: []
modifies: []
modified-by: []
related-adrs: [ADR-0001, ADR-0002]
related-specs: [management-boundaries, access-control, secret-management]
related-changes: [reliable-household-services]
target-architecture: []
---

# Keep public edges independent and identity canonical

## Context and Problem Statement

Household services need a normal remote entrance and a home backup entrance without moving application state. Browser administration needs stronger authorization than an ordinary household login. Native media clients cannot reliably use a browser-only authentication proxy.

## Decision Drivers

- Preserve independent private management when applications, identity or the public edge fail.
- Keep home addressing out of normal service DNS, accepting discoverability through the backup entrance.
- Avoid changing OIDC issuer and passkey origin during recovery.
- Keep one application route inventory and the existing CNI.

## Considered Options

- Put every public function in the application cluster.
- Use independent edges with separate identity origins for each entrance.
- Use independent edges, one canonical identity origin, and explicit DNS failover.

## Decision Outcome

Choose **independent NixOS edges and one canonical Kanidm identity origin**, under delegated authority. Use certificate-verified private origin transport and Gateway API routing compatible with the current CNI. Envoy Gateway supplies browser-administration OIDC; Kanidm supplies administrator membership and strong-authentication policy. Public media/photo/request clients keep supported native authentication. Raw management protocols remain private.

The normal remote edge and home backup share declared routes, not manually duplicated per-service configurations. Fresh browser-administration login through a backup hostname still needs the canonical identity hostname. If its remote entrance fails, the operator must fail that hostname over and allow DNS caches to expire. Registered backup callbacks alone do not remove this dependency.

### Consequences and Confirmation

- The backup edge can provide native-authentication services without replacing the remote edge. Fresh OIDC login is not instantaneous independent failover.
- Neither entrance survives loss of the home origin or home connection. This is not high availability or home-address secrecy.
- Keep break-glass management independent of Kanidm. Do not change issuer or passkey origin to disguise a routing outage.
- Confirm direct-backend denial, non-administrator denial, trusted forwarding, and both entrances in a disposable environment before production activation.
- Reconsider canonical-identity ingress placement if immediate fresh-session failover becomes necessary; do not duplicate identities by default.

## References

- Proposed access contracts: [service-exposure](../../../openspec/changes/reliable-household-services/specs/service-exposure/spec.md).
- Current recovery boundary: [management-boundaries](../../../openspec/specs/management-boundaries/spec.md).
- [Envoy Gateway OIDC](https://gateway.envoyproxy.io/v1.9/tasks/security/oidc/).
- [Kanidm OAuth2 integration](https://kanidm.github.io/kanidm/stable/integrations/oauth2.html).
