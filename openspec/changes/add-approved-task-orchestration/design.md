## Context

The instance already has explicit worker lanes, board-qualified tasks, immutable task-run bindings, and pre-created `parents`/`inputs_from` graphs. Its automatic decomposition watcher treats a `triage` task as rough work to expand, while the same status also receives repeatedly blocked tasks needing operator attention. Managed `kanban_create` does not expose the internal `triage=True` field, so there is no coherent gateway intake path for a user-created rough task.

The useful product is an execution system that remains valuable with one strong worker and selectively uses graphs when task topology justifies their coordination cost. Triage is therefore a trusted control-plane function of the live orchestrator, not a task worker lane or an autonomous multi-agent persona.

## Goals / Non-Goals

**Goals:**

- Recommend solo execution by default and require a concrete, inspectable reason for every graph.
- Obtain exact user approval in the originating conversation before runnable tasks exist.
- Materialize approved tasks and dependency edges as one trusted operation.
- Keep execution lanes capability-based, small, and useful independently.
- Route runtime and publication effects through typed approval-bound adapters.
- Evaluate graphs against a strong solo baseline rather than agent-count intuition.

**Non-Goals:**

- A durable draft board, web proposal editor, or general proposal entity.
- Peer-to-peer worker messaging, shared mutable workspaces, agent personas, or autonomous organizations.
- Automatically decomposing blocker escalations.
- Letting a leaf worker create children or broaden its task graph.
- A generic local-model lane, automatic weak-model routing, or provider-specific lane semantics.
- Implementing VictoriaMetrics, a monitoring platform, knowledge retrieval, or communication-system search.
- Granting an LLM arbitrary SSH, restart, deploy, notification, publication, or canonical-source mutation authority.

## Decisions

### 1. Triage is pre-task conversation state

A user supplies a goal in any gateway handled by the shared Hermes conversation abstraction. The live orchestrator either asks for missing acceptance criteria or renders a proposal. No Kanban task is created while the proposal is pending.

This avoids overloading `triage`, whose supported meaning remains operator attention for existing work such as repeated blockers. The rough-task automatic decomposition watcher is disabled for the supported flow. A future web surface may introduce a durable draft proposal with explicit lifecycle semantics; V1 does not need one.

### 2. Use one proposal contract for solo and graph execution

A proposal contains:

- opaque proposal ID and canonical digest;
- originating conversation identity and orchestrator turn;
- user goal and explicit acceptance criteria;
- mode: `solo` or `graph`;
- bounded task declarations with lane, Project, immutable inputs, output contract, and acceptance check;
- `parents` and `inputs_from` edges;
- synthesis/revision responsibility;
- maximum simultaneously runnable workers and resource/cost ceiling;
- all proposed external effects, normally none during worker execution;
- concise rationale, including why a graph is materially better than solo.

The rendered message includes the digest and exact approval instructions. An approval applies only to that digest, conversation, and unexpired proposal. Any edit creates a new digest and requires new approval.

**Alternative considered:** accept conversational assent such as “looks good.” Rejected because it is ambiguous after revisions and cannot be audited against the executed graph.

### 3. Default to one strong worker

Triage selects `solo` unless the proposed graph satisfies all of:

1. each task has a stable independent input;
2. each task returns a bounded output or selected artifact;
3. tasks need little or no live coordination;
4. outputs can be verified independently;
5. synthesis is cheaper than doing the work serially;
6. the expected benefit in breadth, context capacity, verification, or wall-clock latency exceeds duplicated work, handoff loss, coordination, and model cost.

Approved graph patterns are deliberately small:

- **map:** the same operation over independent inputs;
- **research fan-out/fan-in:** distinct evidence axes followed by cited synthesis;
- **independent review:** producer, fresh reviewer, then revision or adjudication;
- **tournament:** independent candidate solutions followed by objective tests or human selection;
- **pipeline:** ordered transformations with immutable handoffs;
- **latency hiding:** independent external waits or bounded operations executed concurrently.

A large goal, decorative role diversity, or the availability of cheap models is not sufficient.

### 4. Separate coordinator and leaf authority

The live orchestrator may propose and, after approval, materialize a graph. A leaf worker receives one frozen task and may complete, block, or return a structured request for clarification or follow-up. It cannot invoke task creation, graph mutation, approval, publication, or operational effects.

Follow-up work returns to the originating orchestrator. The orchestrator may create it only when the approved proposal already authorized that bounded continuation; otherwise it renders a revised proposal and obtains a new digest-bound approval.

### 5. Materialize an approved graph atomically

A trusted graph-materialization route validates the active board, lane catalogue revision, Projects, input capability, dependency acyclicity, fan-out ceilings, and proposal digest before creating any task. Creation either commits the complete task and edge set or creates nothing.

The route accepts semantic task declarations but not profiles, host paths, providers, policy worklanes, broker IDs, workspace IDs, leases, mounts, credentials, or environment keys. Existing trusted dispatch resolves those facts later.

A replay with the same proposal digest returns the original graph. A changed proposal or catalogue conflict fails without partial creation. The live orchestrator receives stable task IDs and renders the resulting graph in the originating conversation.

### 6. Keep the initial catalogue small and capability-based

- `general`: strongest default for one coherent analytical, planning, research, or synthesis goal. Scratch workspace, public information access, immutable inputs, bounded output; coordinator eligibility belongs to the live orchestrator, not this leaf lane.
- `code`: implements and verifies one trusted Project in a private writable workspace. Produces a candidate Project result and selected artifacts; no canonical publication.
- `review`: independently inspects a read-only Project generation or completed candidate and writes a report under output. No Project mutation or children.
- `ops-observe`: consumes typed read-only homelab observations and returns diagnosis plus proposed remediation. It does not receive arbitrary SSH or operational mutation.

Lane descriptions advertise when to select them, their input/output contract, and prohibited effects. Exact model names remain operator configuration. Triage, synthesis, `code`, `review`, and `ops-observe` use the strongest suitable configured model initially.

`local-extract` remains an unregistered future option until a narrow immutable-input, strict-schema, offline workload beats the baseline with mandatory strong-model or deterministic verification. Mechanical transforms should use programs rather than a weak model.

### 7. Operational and publication effects are control-plane actions

`ops-observe` may recommend an exact restart/reload, deployment/rollback, Git-mediated remediation, or incident notification. A trusted adapter performs an approved action; the worker never receives a general mutation shell.

The originating DM or group is the default notification destination. Approval binds the typed action, target, revision where applicable, destination, expiry, and proposal digest. Git publication likewise binds the immutable candidate result and expected destination generation. A private workspace write is never acceptance or publication.

Typed status/log/metric adapters may initially be sparse. Future VictoriaMetrics integration can supply observations without changing lane semantics. Missing observation support fails as unavailable; it does not fall back to arbitrary SSH.

### 8. Use gateway-neutral proposal rendering and approval

The orchestration layer emits one structured proposal event through the shared gateway messaging/approval abstraction. Telegram, Discord, and future gateways render the same semantic content and return the same digest-bound decision. No lane or graph policy is implemented inside platform adapters.

V1 uses textual approve, revise, and run-solo actions. Gateway-specific buttons and the web board may be added later against the same contract.

### 9. Evaluate before widening fan-out

Three acceptance workflows compare the proposed topology with one strongest-suitable solo worker:

1. nontrivial Project implementation and verification;
2. breadth-first technical investigation with citations;
3. implementation, independent review, and revision.

Record completeness, correctness, source quality, verification outcome, wall time, model usage/cost, duplicated work, handoff loss, and integration conflicts. Graph execution is retained for a pattern only when it produces material benefit after those costs. Results tune policy defaults but do not silently alter an already approved proposal.

## Risks / Trade-offs

- **[Risk] Triage itself adds latency and model cost.** Use the live orchestrator and allow an immediate solo proposal for ordinary coherent goals.
- **[Risk] A persuasive proposal obscures unnecessary fan-out.** Require explicit graph criteria, worker ceiling, cost, and solo comparison rationale.
- **[Risk] Approval races catalogue or Project changes.** Validate the active revision during atomic materialization and require a revised proposal on conflict.
- **[Risk] Generic gateway support becomes lowest-common-denominator UX.** Keep the semantic contract shared and let adapters add presentation without changing authorization.
- **[Risk] Leaf follow-up requests become covert child creation.** Return them to the orchestrator and require prior bounded authorization or a new proposal.
- **[Risk] `ops-observe` becomes an arbitrary operations shell.** Expose typed observations only; keep every mutation in an exact control-plane adapter.
- **[Risk] Strong-model-only defaults cost more per task.** Optimize total successful-work cost, not token price; introduce moderate/local leaves only after measured bounded wins.
- **[Risk] Proposal state disappears on gateway restart.** V1 may require the user to request a fresh proposal; it must never infer approval or create tasks from an unverifiable stale message.
