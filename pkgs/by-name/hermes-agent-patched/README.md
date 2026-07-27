# Locally patched Hermes Agent

This package applies the ordered compatibility and security patch stack used by
the Hermes QA and production workloads. Patches should remain independently
reviewable, carry behavior-focused tests, and be removed when the pinned Hermes
release provides an equivalent contract.

`package.nix` is the authoritative patch order. Later patches may deliberately
specialize generic behavior established earlier in the stack.

## Patch ownership

The stack has four broad layers:

1. **Generic Hermes extensions** — worker-lane registration and discovery,
   platform Kanban toolsets, approval semantics, and backend-independent Kanban
   lifecycle safety.
2. **Secure execution** — conversation-scoped terminal identity, Gondolin
   transport and cancellation, and task authority binding.
3. **Workspace broker** — private workspaces, immutable revisions, publication,
   parent-to-child import, finalization, and outage recovery.
4. **Deployment guidance** — compact role-specific instructions that describe
   this deployment's workspace-output protocol without moving it into the
   generic patches.

Important ownership boundaries:

- `kanban-lifecycle-safety.patch` is generated against pristine pinned Hermes.
  It owns generic lifecycle correctness, worker/live-orchestrator role
  separation, and model-facing lifecycle-tool authority.
- `kanban-platform-toolsets.patch` owns Kanban opt-in through modern
  `platform_toolsets`; its tests assert the final live-orchestrator tool surface.
- `kanban-worker-guidance.patch` is generated against the preceding local patch
  stack. It owns only compact deployment guidance and the Gondolin
  workspace-output choreography.
- `workspace-*.patch` and `task-authority-binding.patch` own the actual trust and
  persistence mechanisms. Prompt text is not a substitute for those controls.

Each mail-formatted patch carries a subject and body explaining why it remains
after a Hermes upgrade. Preserve or update that message when regenerating a
patch.

## Kanban roles

Hermes selects the role from trusted process context:

- `HERMES_KANBAN_TASK` set: dispatcher-assigned worker.
- Kanban-enabled profile without that variable: live orchestrator.
- Neither: no Kanban contract or tools.

The model-facing tools are intentionally partitioned:

| Tool | Worker | Live orchestrator |
| --- | --- | --- |
| `kanban_show` | yes | yes |
| `kanban_create` | yes | yes |
| `kanban_comment` | yes | yes |
| `kanban_link` | yes | yes |
| `kanban_complete` | yes, own task | no |
| `kanban_block` | yes, own task | no |
| `kanban_heartbeat` | yes, own task | no |
| `kanban_list` | no | yes |
| `kanban_unblock` | no | yes, after resolution |

A dispatched planner is still a worker: it owns one board task, may create child
tasks, and must complete or block its own task. A live orchestrator routes and
observes work; it must not execute child task bodies or manufacture child
lifecycle events.

### Natural orchestration patterns

- **Independent fan-out:** create each task with the assignee whose declared
  capability matches the work. No parent edge is needed merely because tasks
  were created in the same conversation.
- **Dependency or fan-in:** create the dependent task with `parents`. It remains
  gated until all parents are done and receives their summaries and metadata.
  Pre-creating this graph is normal.
- **Worker-discovered follow-up:** the worker creates a bounded child or sibling
  task instead of expanding its own scope.
- **External worker lane:** select it by the capability advertised in the
  dynamic `assignee` schema, not by the current profile's identity.
- **Blocked work:** the worker records the genuine blocker once. The live
  orchestrator may add context and unblock only after the blocker is confirmed
  resolved or the task contract explicitly authorizes the retry.

Workspace revision inheritance is the exception to normal pre-created graphs.
When a downstream task must receive files published through
`workspace_outputs`, the live orchestrator creates only the producer and puts
the downstream contract in its body. The producer then creates one direct child
with `inherit_parent_workspace_output=true` before completing and publishing.
This ordering binds the import to the trusted producer identity and immutable
revision. Ordinary parent-summary and metadata handoffs do not require this
special topology.

`kanban_block` is not cancellation: it changes task state but does not terminate
a running worker. Use `max_runtime_seconds` when work needs a runtime bound; the
dispatcher terminates an overrun and applies retry/circuit-breaker policy.
Immediate operator cancellation remains a separate capability gap and should
eventually be implemented as an explicit cancel operation, not by exposing
`kanban_block` to the live orchestrator.

## Secure terminal and workspace boundary

`secure-terminal-isolation.patch` supplies canonical environment identity,
engine-owned volumes, and suppressible gateway-side support mounts. Nix keeps
those controls operator-owned through environment variables rather than model
tool arguments.

The NixOS Hermes account aspect supplies the dedicated sandbox account and
systemd-activated capability sockets. Gondolin execution and control use
separate sockets; the gateway receives only the paths required by its role.

The workspace broker, not the prompt, enforces:

- private task workspaces;
- activation-bound execution authority;
- immutable selected-output revisions;
- direct-child-only trusted import;
- finalization replay after broker outages; and
- revocation and cleanup.

See `HERMES_NIX_SECURE_TERMINAL_BACKEND.md` and the workspace acceptance runbook
for the threat model and deployment tests.

## Updating pinned Hermes

1. Check whether upstream now provides each patched contract. Remove obsolete
   patches rather than retaining compatibility shims.
2. Preserve `package.nix` ordering and apply patches through the patch being
   upgraded.
3. Materialize that exact intermediate source, edit a scratch copy, and generate
   the patch with `git diff --no-index` or `diff -u`. Do not hand-author unified
   diff hunk counts.
4. Keep generic patches free of Gondolin, workspace-output, or Codex behavior.
   Keep deployment-specific guidance in the later guidance patch.
5. Update the embedded patch subject/body when purpose, ownership, or retained
   behavior changes.
6. Verify with the real Nix `applyPatches` path. Local BSD `patch` or
   `git apply` is not equivalent to nixpkgs' GNU patch behavior.
7. Run:

   ```sh
   nix build --no-link .#checks.aarch64-darwin.hermes-worker-lane
   nix flake check --option sandbox false
   ```

   The sandbox override is required on aarch64-darwin because the Hermes Python
   environment can be killed while importing ffmpeg dylibs in the Nix sandbox.

Do not add Codex prompts, authentication, executable paths, or policy to the
generic worker-lane patches. Those belong to the separately packaged Codex lane
or the deployment-specific guidance layer.
