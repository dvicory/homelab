---
id: ADR-0003
status: accepted
date: 2026-09-22
decision-makers: [Daniel Vicory]
consulted: []
informed: [Homelab operator]
supersedes: []
superseded-by: []
modifies: []
modified-by: []
related-adrs: [ADR-0002]
related-specs: [management-boundaries]
related-changes: [independent-service-exposure-contract]
target-architecture: []
---

# Keep ingress entrances independent and identity canonical

## Context

Household services need a private Kubernetes entrance and independently recoverable public entrances. Shared identity must not change issuer or certificate identity when traffic fails over between those entrances.

## Decision

Keep one declared route inventory. The Kubernetes Gateway consumes every route; each public edge consumes only public routes and validates its own hostname shape. Trusted-edge mode accepts forwarded client-address metadata only from declared peers. The first trusted proxy discards client-supplied forwarding, end-user identity, and request-ID metadata, creates a fresh request ID, and omits query strings from access logs.

Use the first identity-route hostname as Kanidm's canonical issuer, SNI, and public-PKI certificate identity through direct and failover access. DNS may redirect traffic to another entrance; it does not create another identity hostname.

Stage identity as `initial`, `provisioning`, then `normal`. Provisioning rights reconcile before the provisioning Job. Administrator policy and route share one normal-only Argo Application, with policy ordered before route publication.

The independent recovery path remains governed by `management-boundaries`. This decision does not make application workloads own shared ingress or identity infrastructure.

## Consequences

- One failed application does not own or disable shared ingress, identity, or unrelated routes.
- Public failover depends on DNS and certificate operations but not on a second identity issuer.
- Public administrator routes remain absent until provisioning and private login verification succeed.
- Live DNS, certificate, authentication, request-ID, logging, and failure-isolation evidence remains separate from structural evaluation.

## Reconsideration triggers

Revisit this decision if Kanidm moves to private PKI, public entrances can no longer share one canonical identity hostname, or a provider requires a different trusted-proxy model.
