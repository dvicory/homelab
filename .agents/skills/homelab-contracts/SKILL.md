---
name: homelab-contracts
description: Use before Homelab architecture or implementation work when deciding whether a proposed Nix/Den change needs an OpenSpec contract change. Especially relevant to changes in architecture or ownership boundaries, access/security guarantees, storage/persistence safety, recovery/failure domains, deployment domains, or shared-infrastructure/application integration. Do not use for routine configuration or implementation changes that remain within current contracts.
---

# Homelab contract gate

Before choosing an OpenSpec workflow, determine whether the proposed work changes a durable Homelab contract or only its concrete implementation.

A contract change alters an intended long-lived guarantee or boundary, such as architecture or ownership, access or security, recovery or failure domains, lifecycle, or integration behavior. Use OpenSpec when one of those durable decisions changes.

If the intended contract remains the same and only concrete desired state or implementation changes, work directly in Nix/Den.

When uncertain, identify the durable decision independently of the current mechanism. If no such decision is changing, an OpenSpec change is probably unnecessary.

When the distinction is unclear, ask:

1. Would a substantially different implementation still satisfy the intended Homelab behavior? If yes, specify the behavior rather than the mechanism.
2. Is this fact better represented directly in Nix or derived documentation?
3. Does this behavior belong to an independently developed application's repository rather than Homelab?
4. Which existing capability owns the durable decision? Create a new capability only when the decision is genuinely distinct.
