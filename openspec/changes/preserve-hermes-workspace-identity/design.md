## Context

Hermes has three distinct identities that must not be conflated:

1. the gateway routing key, which selects a platform/chat/thread delivery route and may be rebound by `/resume` or another adapter;
2. the live transcript segment ID, which changes when context compression creates a continuation;
3. the broker workspace owner, which must remain stable for one logical conversation while preserving explicit isolation boundaries.

The current terminal helper prefers the approval/gateway session key. The sandbox plugin also stores process-local session-to-environment mappings only when `on_session_start` fires. Neither is a durable workspace ownership contract.

## Decisions

### Persisted workspace identity

Hermes SHALL derive a workspace session ID from persisted session records and bind it into a private task-local `ContextVar` before any model tool runs. The field SHALL NOT be part of the `HERMES_*` compatibility map, subprocess environment bridge, guest environment, model-visible tool arguments, or logs. The resolver follows only compression-continuation edges. It SHALL NOT infer ownership from a platform, chat, thread, gateway route, title, user-supplied identifier, or process-local cache.

`trusted_session_key` SHALL prefer this private workspace session ID for environment-backed surfaces. Approval delivery continues to use the gateway session key; changing workspace ownership MUST NOT change approval routing.

If persisted lineage cannot be read, the resolver uses the current transcript segment as a fresh isolated owner. It MUST NOT fall back to a potentially foreign process-global or gateway key. Only the derived opaque canonical environment key may cross the broker API.

### Resume and compression

`/resume` reuses the stored session lineage. Compression continuations resolve to the root of the compression-only chain. Both therefore derive the same canonical environment key and broker authority binding.

### New conversations and delegated execution

`/new` creates a root with no compression predecessor and therefore a fresh owner. Explicit branch markers, delegate markers, tool sessions, and ordinary parent links are not compression edges. Delegated and tool execution retain their existing exact task/run authority contracts and cannot inherit conversation ownership by walking a generic parent chain.

### Private branch inheritance

A branch receives a distinct canonical environment key. Before Hermes switches the active route to the branch, the trusted lifecycle invokes a required broker branch-preparation operation with the source and destination environment identities and an idempotency key derived from the new persisted branch session.

The broker SHALL:

1. resolve or create broker-owned authority/workspace bindings for both identities;
2. serialize against environment mutation;
3. close and drain the source VM so no VFS write races the copy;
4. copy the complete source workspace into a detached broker-owned temporary;
5. create a private destination workspace and lease;
6. atomically install the copied tree and journal the completed source/destination facts;
7. leave the source workspace active and reusable, but with no live VM until the next ensure.

Parent and child receive different workspace IDs, lease IDs, fencing tokens, and future VM generations. Later writes never propagate between them. An empty parent workspace produces an empty private child.

A replay with the same operation ID and facts returns the same destination binding. Changed facts conflict. A failure before completion blocks the Hermes branch switch. Hermes MUST NOT substitute an empty, local, Docker, Podman, or shared workspace. Any provisional branch session record is deleted or remains non-selectable until preparation succeeds.

### Lifecycle authority binding

The sandbox lifecycle plugin SHALL restore the stable workspace identity before every model-facing tool call because stored-prompt resume paths do not reliably emit `on_session_start`. Registration is idempotent and task-local. Process-local maps may optimize cleanup but are not authority sources.

## Risks and mitigations

- **Copy consistency:** copying a live VFS tree can mix generations. The broker closes/drains the source VM before copying.
- **Branch latency and disk use:** a full private copy costs proportional I/O and storage. Correct isolation takes precedence; reflinks or content-addressed trees may be added later without changing the contract.
- **Orphaned preparation:** journaled idempotency and destination uniqueness make retries safe; failed provisional branch records are not activated.
- **Cross-session disclosure:** only persisted compression edges reattach. Branch inheritance requires a trusted lifecycle call and produces a private copy. Generic parent traversal is forbidden.
- **Restart behavior:** broker records and workspace directories, not Python dictionaries, remain authoritative.
- **Filesystem fidelity:** branch copy preserves ordinary file bytes, directories, modes, timestamps, and symlinks. Exact preservation of xattrs, ACLs, sparse allocation, or hardlink identity is not part of this change; unsupported special entries fail branch preparation rather than weakening isolation.
- **Duplicate staging machinery:** Kanban handoffs and conversation branches intentionally enforce different source/validation semantics. A later refactor may extract shared detached-staging, atomic-install, and replay helpers, but must not apply artifact-export restrictions to project branches or relax Kanban validation.

## Future work: broker-managed durable mounts

The current broker exposes one durable VFS authority at `/workspace`. No existing OpenSpec defines additional durable mounts for profiles, agents, or worker lanes. A separate `broker-managed-durable-mounts` change should define trusted Nix-declared volume names, fixed guest paths, ownership, read/write modes, independent leases and fencing, VM-generation changes, branch/copy behavior, retention, quotas, audit, and cleanup. Model-selected or caller-supplied host paths must remain prohibited; arbitrary host bind mounts would bypass broker ownership and host-path non-disclosure.
