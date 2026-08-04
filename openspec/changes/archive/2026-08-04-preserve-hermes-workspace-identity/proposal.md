## Why

The deployed QA Gondolin integration derives conversation workspace authority from mutable process-local values. Gateway routing keys can change across adapters and `/resume`, while Hermes session IDs rotate during compression. A resumed conversation can therefore acquire a fresh broker workspace and lose access to prior files. Existing OpenSpec text says that each conversation receives a workspace but does not define the durable identity or branch behavior.

## What Changes

- Bind every conversation-backed execution surface to a stable workspace owner derived from persisted Hermes session lineage, never from a gateway route alias.
- Reattach `/resume`, cross-gateway aliases, and compression continuations to the same broker workspace.
- Give `/branch` a private writable workspace initialized from a quiesced copy of its parent workspace; parent and branch never share a lease or later mutations.
- Keep `/new`, delegated/subagent sessions, tool sessions, and unrelated conversations isolated unless an existing explicit handoff contract authorizes transfer.
- Add a required branch-preparation lifecycle contract for broker-backed conversations. A failed clone blocks the branch switch and must not silently create an empty workspace.
- Add focused regressions that exercise identity derivation without requiring a live messaging platform.

## Capabilities

### New Capabilities

- `hermes-conversation-workspace-identity`: Stable conversation workspace ownership, resume/compression reattachment, private branch inheritance, and fail-closed branch preparation.

### Modified Capabilities

None. The existing `kanban-sandbox-workspace` capability governs task/run workspaces and parent-child handoffs, not gateway conversation lifecycle.

## Affected Configurations

- QA `hermes-qa` Gondolin-backed conversations on `hvn-hyp1`.
- The patched Hermes gateway/session-context and terminal identity integration.
- The Nix-managed `hermes-sandbox-access` lifecycle plugin.
- The Gondolin Effect broker control API and workspace registry.
- No production cutover and no rootless-Podman behavior change.

## Non-goals

- Sharing a writable workspace between parent and branch.
- Copying conversation workspaces into Kanban tasks or vice versa.
- Exposing raw session IDs, gateway keys, workspace IDs, leases, or host paths to the model.
- Migrating already mis-keyed QA workspaces automatically; deployment verification identifies and handles any affected QA state explicitly.
