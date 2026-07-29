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
3. **Workspace broker** — private workspaces, hashless frozen output,
   publication, parent-to-child import, finalization, and outage recovery.
4. **Deployment guidance** — compact role-specific instructions that describe
   this deployment's relative-artifact protocol without moving it into the
   generic patches.

Important ownership boundaries:

- `kanban-lifecycle-safety.patch` is generated against pristine pinned Hermes.
  It owns generic lifecycle correctness, worker/live-orchestrator role
  separation, and model-facing lifecycle-tool authority.
- `kanban-platform-toolsets.patch` owns Kanban opt-in through modern
  `platform_toolsets`; its tests assert the final live-orchestrator tool surface.
- `kanban-worker-guidance.patch` is generated against the preceding local patch
   stack. It owns only compact deployment guidance and the Gondolin
   frozen relative-artifact choreography.
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

Hashless frozen-output inheritance is the exception to normal pre-created graphs.
When a downstream task must receive a producer's selected relative artifacts,
the live orchestrator creates only the producer and puts the downstream
contract in its body. The producer then creates one direct child with
`inherit_parent_output=true` before completing and publishing. This ordering
binds the import to the trusted producer identity and frozen output manifest.
Ordinary parent-summary and metadata handoffs do not require this special
topology.

## Planned: multi-parent artifact inputs

**Not implemented; outside current acceptance.** Writable broker inheritance is
one-parent only; the current Swarm verifier uses summaries, metadata, and
comments rather than opening files from multiple workers. A file-consuming
child cannot be pre-created: its producer must create it during the run, so
the full file pipeline is not visible or editable up front. Users must rely on
summaries/metadata/comments or explicit external publication; retries need
idempotent child creation, and each writable import copies storage.

The desired future UX is explicit pre-created `inputs_from` edges: inspect the
full DAG, receive read-only namespaced parent inputs at
`/workspace/inputs/<parent-task>/`, and never perform an implicit merge. Until
then, only one-parent writable `inherit_parent_output` and metadata-only Swarm
fan-in are supported.

The implementation sequence is explicit worker lanes, immutable-output handoffs,
broker Project workspaces, then multi-task inputs. The handoff workstream removes
the current writable `inherit_parent_output` path rather than completing or
extending it; the later input workstream starts from reusable immutable handoffs.

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

Detached Codex lanes receive one frozen permission profile that projects
filesystem and network policy independently. Their non-interactive process
cannot surface approvals to the live operator, so configured lanes must disable
Codex approval escalation. The live orchestrator's `terminal`, `file`,
`process`, and `sandbox` tools continue to address only its conversation
environment; a worker path such as `/workspace` is descriptive, not a
cross-environment address.

The workspace broker, not the prompt, enforces:

- private task workspaces;
- activation-bound execution authority;
- hashless frozen selected-output manifests;
- direct-child-only trusted import (current implementation, removed by the immutable-output handoff workstream);
- finalization replay after broker outages; and
- revocation and cleanup.


### Planned: shared broker workspace staging primitives

**Not implemented.** Kanban handoffs and conversation branches now both
quiesce a broker-owned source, copy through detached staging, install private
destination storage, and journal replay. Their policy contracts differ:
Kanban captures validated immutable `/workspace/output` artifacts, while a
conversation branch copies the complete working project and preserves ordinary
repository symlinks.

Extract the common mechanics into broker-internal primitives for detached
staging allocation, atomic directory installation, crash/replay state
transitions, and staging cleanup. Keep source selection and validation
caller-specific. The refactor must not weaken Kanban traversal/type/size
validation, apply artifact-export restrictions to project branches, introduce a
model-facing generic copy API, or permit caller-selected host paths.

### Planned: guest source introspection

**Not implemented.** Gondolin workers can read only their guest image and
broker-confined `/workspace`; Hermes read/search/terminal tools do not expose
the host repository or `/nix/store`. Consequently an agent cannot currently
inspect the exact Hermes implementation driving its session.

A future implementation may publish the exact applied Hermes source, patch
provenance, and build identity at a stable read-only guest path such as
`/usr/share/hermes-source`. Expose that bounded snapshot rather than the host
repository or the complete `/nix` tree, which would disclose unrelated host
artifacts and greatly expand the VFS attack surface.

### Planned: Gondolin background-process stdin

**Not implemented.** Foreground commands can receive bounded input, but
Gondolin background-process schemas deliberately omit `write`, `submit`, and
`close`; direct stale calls return `unsupported_capability`. Output polling and
acknowledged cancellation remain available.

Future stdin support requires a broker-owned bidirectional process session with
an opaque execution id, exact environment generation and task-run ownership,
bounded input/rate/deadline policy, explicit EOF, cancellation ordering, and
defined disconnect/restart behavior. PTY input and resize are a separate
capability. Do not emulate either with gateway-local buffering or prompt text.

See `HERMES_NIX_SECURE_TERMINAL_BACKEND.md` and the workspace acceptance runbook
for the threat model and deployment tests.

## Upgrade invariants

`check.nix` runs the focused seams below; keep their contracts stable across
upgrades:

- Metadata-only, nonexecuting Swarm roots remain `done` with broker descendants:
  `tests/hermes_cli/test_kanban_swarm.py`.
- No implicit multi-parent filesystem merge; only one-parent writable imports are
  accepted: `tests/hermes_cli/test_kanban_swarm.py`.
- Hermes adds no custom authority schema: `tests/plugins/test_workspace_zero_schema.py`.
- Board-qualified `taskRun` identities and the exact environment key remain
  aligned: `tests/tools/test_gondolin_backend.py` and
  `tests/tools/test_task_authority_binding.py`.
- `output/` selection is preflighted and frozen before completion:
  `tests/tools/test_kanban_tools.py`.
- Delivery uses attachment manifests only; summary/result prose is never scanned:
  `tests/gateway/test_kanban_notifier.py`.
- Approval choices remain bounded by durable-grant policy:
  `tests/tools/test_approval_choice_result.py`.

## Updating pinned Hermes

1. **Audit interactions first.** Inventory upstream APIs, features, model
   schemas/prompts, persistence/recovery, and new or changed tests against the
   retained invariants before porting; this is how compatibility gaps such as
   Swarm topology become visible.
2. **Regenerate with provenance.** Rebuild adjacent stages from exact
   predecessors and preserve durable WHAT/WHY/IMPACT plus split rationale
   through consolidation. Deliver only authoritative patch files; drop
   version/rebase diary and temporary trees.
3. **Verify boundaries, not just application.** Reconcile `check.nix` with every
   modified/new test, then verify cross-process identity and authority,
   irreversible recovery/state transitions, and model schema/runtime parity.
   Apply/compile is insufficient: run focused seams and the full ordered Nix
   check.
4. **Trace capabilities end to end.** For each retained or changed capability,
   follow producer → authority/durable state → consumer → acknowledgement,
   cleanup, and recovery; execute one representative workflow. Helpers and unit
   seams do not prove delivery—this catches orphaned exports and workspace
   mismatches.
Verify with the real Nix `applyPatches` path. Local BSD `patch` or `git apply` is
not equivalent to nixpkgs' GNU patch behavior. Then run:

   ```sh
   nix build --no-link .#checks.aarch64-darwin.hermes-worker-lane
   nix flake check --option sandbox false
   ```

   The sandbox override is required on aarch64-darwin because the Hermes Python
   environment can be killed while importing ffmpeg dylibs in the Nix sandbox.

Do not add Codex prompts, authentication, executable paths, or policy to the
generic worker-lane patches. Those belong to the separately packaged Codex lane
or the deployment-specific guidance layer.
