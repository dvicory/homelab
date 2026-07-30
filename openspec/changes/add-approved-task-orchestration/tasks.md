## 1. Triage and proposal contract

- [ ] 1.1 Add a typed solo/graph proposal containing goal, acceptance criteria, bounded tasks, registered lanes, logical Projects, immutable inputs, `parents`/`inputs_from` edges, output contracts, synthesis responsibility, concurrency and resource ceilings, external effects, rationale, origin, expiry, ID, and canonical digest.
- [ ] 1.2 Add live-orchestrator policy that defaults to one strongest-suitable worker and permits only map, research fan-out/fan-in, independent review, tournament, pipeline, or latency-hiding graphs satisfying the separability and material-benefit criteria.
- [ ] 1.3 Keep proposed goals in conversation state before approval; disable the supported rough-task auto-decomposition path and reserve operational `triage` for existing-task operator attention.
- [ ] 1.4 Render solo/graph proposals through the shared gateway conversation abstraction with textual approve, revise, and run-solo actions.
- [ ] 1.5 Bind approval to the exact proposal digest, originating conversation, user decision, and expiry; reject stale, revised, unverifiable, or cross-conversation approval.

## 2. Trusted graph materialization

- [ ] 2.1 Add an orchestrator-only atomic graph creation route that validates one active board, lane/Project catalogue revision, registered lanes, Projects, edge acyclicity, input capability, ceilings, and proposal digest before creating tasks.
- [ ] 2.2 Make identical approved-digest replay return the original graph and make changed facts or partial failures create no runnable subset.
- [ ] 2.3 Keep profiles, providers, host paths, policy worklanes, broker/workspace/lease/mount identities, credentials, and environment keys out of the proposal and graph API.
- [ ] 2.4 Remove task creation and graph mutation from leaf-worker schemas and backend authority; return structured follow-up requests to the live orchestrator.
- [ ] 2.5 Permit follow-up task creation only when prior approval bounded it or a revised digest receives new approval.
- [ ] 2.6 Render created task identities, edges, current states, outputs, and verification results back to the originating conversation.

## 3. Initial capability catalogue

- [ ] 3.1 Replace the starter research/codex catalogue with semantic `general`, `code`, `review`, and `ops-observe` declarations whose descriptions state suitable goals, inputs, outputs, capability ceilings, and prohibited effects.
- [ ] 3.2 Configure the strongest suitable operator-selected model for triage, synthesis, and every initial lane without encoding provider names in lane semantics.
- [ ] 3.3 Give `general` scratch/public-research capability, immutable inputs, and bounded outputs without child creation or effects.
- [ ] 3.4 Give `code` one private writable Project workspace and candidate-result completion without publication, gateway secrets, broker sockets, or canonical mutation.
- [ ] 3.5 Give `review` read-only Project/result access and writable bounded report output without Project mutation or child creation.
- [ ] 3.6 Give `ops-observe` only typed read-only observations and proposed-remediation output; fail unavailable observation types rather than falling back to arbitrary SSH.
- [ ] 3.7 Keep `local-extract` unregistered and document its future immutable-input, offline, strict-schema, bounded, verified admission criteria.

## 4. Approved control-plane effects

- [ ] 4.1 Define typed effect proposals for restart/reload, deploy/rollback, Git-mediated remediation/publication, and originating-conversation notification with exact target, relevant revision, content, expiry, and proposal/result binding.
- [ ] 4.2 Route each approved effect through a deterministic adapter unavailable to worker lanes; do not expose a general host mutation or publication shell.
- [ ] 4.3 Preserve candidate Project results independently of publication and enforce expected-destination generation before an approved Git effect.
- [ ] 4.4 Deliver approved incident notifications only to the bound originating DM or group.

## 5. Verification and baseline evaluation

- [ ] 5.1 Verify no task exists before approval; exact approval creates the full graph; revision, expiry, cross-conversation use, catalogue drift, response loss, and partial failure remain fail-closed and replay-safe.
- [ ] 5.2 Verify blocker escalations are not decomposed and leaf workers cannot create tasks, mutate graphs, approve proposals, publish results, or invoke operational effects through visible, hidden, stale, or indirect routes.
- [ ] 5.3 Verify identical proposal and approval semantics through at least the configured Telegram and Discord gateways without lane-specific adapter behavior.
- [ ] 5.4 Smoke-test one solo Project implementation, one research fan-out/fan-in with cited synthesis, and one implementation/review/revision graph end to end.
- [ ] 5.5 Compare each graph workflow with the strongest-suitable solo baseline and record correctness, completeness, verification, source quality, wall time, model usage/cost, duplicated work, handoff loss, and integration conflicts.
- [ ] 5.6 Keep graph patterns and any weaker-model leaf disabled by default unless the measured result provides material benefit after coordination cost.
- [ ] 5.7 Run focused Hermes, Kanban, gateway, broker, Nix-module, policy, and end-to-end checks for the approved orchestration path.
