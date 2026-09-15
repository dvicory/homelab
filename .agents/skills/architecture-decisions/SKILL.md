---
name: architecture-decisions
description: Create, review, evolve, and reconcile Architecture Decision Records (ADRs) using MADR 4.0. Use for durable architecture-significant choices and when proposed work may conflict with existing architectural decisions. ADRs preserve decisions and rationale without replacing target architecture, normative specifications, or current implementation/configuration.
---

# Architecture Decisions

Use MADR 4.0 as the ADR format and this skill as the repository's decision-history process.

Read `references/TEMPLATE.md` when creating an ADR. Use `references/REVIEW.md` for substantive review, acceptance, modification, supersession, or architecture reconciliation.

## Operating principle

Use judgment throughout this skill. Examples and workflow guidance are defaults, not exhaustive rules. Adapt the process to the scope and obvious repository context while preserving two invariants:

1. **authority boundaries remain clear**, and
2. **the effective current decision remains unambiguous**.

Do not add ceremony when the answer is already established by repository evidence or an explicit user decision.

## What an ADR is

An ADR records **an architecture-significant choice, the context in which it was made, the alternatives considered, why it was chosen, and its durable consequences**.

Keep these roles distinct:

- **Target architecture** describes the intended destination and architectural direction, including choices that may still be tentative.
- **ADRs** preserve proposed and settled choices and their rationale. An accepted ADR establishes that a choice was made; it does not automatically make every explanatory sentence a normative requirement.
- **OpenSpec** owns normative requirements, invariants, behavioral contracts, and other statements that must remain true.
- **Active OpenSpec changes** describe proposed changes to normative authority; they are not accepted authority merely because they exist.
- **Nix and other implementation/configuration** describe the current realization. They are evidence about reality, not automatically evidence of architectural intent.

An ADR may summarize an authoritative requirement when it is needed to understand the decision, but should link to the requirement's authoritative source and must not redefine it or become its only home.

Do not turn an ADR into an implementation plan or executable specification. Implementation details belong when they are themselves part of the architectural decision; incidental paths, package versions, commands, and task breakdowns usually do not.

## When an ADR is useful

Use judgment. Signals that a choice probably deserves an ADR include:

- reversing it later would require meaningful migration or coordinated change;
- it establishes a trust, security, isolation, identity, or secret-management boundary;
- it chooses a durable platform, runtime, orchestration, networking, storage, deployment, observability, or service-placement model;
- it establishes a cross-cutting architectural pattern or responsibility boundary;
- it chooses a protocol, persistent data format, compatibility contract, or dependency that creates long-lived coupling;
- multiple credible alternatives exist and future agents are likely to reopen the choice without its rationale;
- it settles or intentionally changes part of the target architecture.

Examples may include host/guest isolation technology, Kubernetes placement, CNI/network-policy direction, ingress/TLS/auth responsibility, image/secret bootstrap architecture, or a cache trust model.

An ADR is usually unnecessary for routine Nix options, ordinary package additions, file layout, refactors, version bumps, transient experiments, implementation task lists, or statements that merely describe current or target state.

A useful final test is: **Would a future maintainer benefit from knowing why this choice was made after the implementation has changed substantially?**

## Storage and identity

Follow an established ADR location if the repository already has one. Otherwise prefer:

`docs/architecture/decisions/NNNN-short-decision-title.md`

Use a four-digit monotonically increasing identifier. Never renumber existing ADRs to remove gaps.

The stable identity is `ADR-NNNN`. Avoid casually renaming accepted ADR files because links may depend on them.

## Gather enough context

Before proposing or changing an architectural decision, consult the context relevant to that decision. This commonly includes:

- repository governance and architectural-authority guidance;
- relevant target-architecture sections;
- relevant accepted OpenSpec specifications;
- relevant active OpenSpec changes;
- related ADR history, including rejected and superseded decisions when useful;
- current Nix/configuration/implementation and tests;
- external evidence needed to compare alternatives.

There is no required reading order. Inspect what helps answer the decision efficiently, while interpreting each artifact according to its authority role.

Do not infer architectural intent solely from current Nix or code. Surface material disagreement among current realization, target architecture, specs, and accepted decisions rather than silently resolving it in favor of whichever artifact was read first.

## Creating a decision record

Aim for one coherent decision question at a scope that will remain understandable later. Prefer separable ADRs when choices can evolve independently, but do not split a tightly coupled decision merely to satisfy a mechanical rule.

A good ADR normally captures:

- the architectural problem and relevant scope;
- the forces and decision drivers that actually discriminate between options;
- credible alternatives, including the status quo when genuinely viable;
- the selected direction and why it won;
- positive, negative, and neutral consequences;
- assumptions that materially affected the choice;
- reconsideration triggers;
- optional Confirmation that can detect continuing architectural conformance;
- meaningful relationships to prior ADRs, target architecture, specs, and active changes.

Use `proposed` while a consequential choice remains unresolved. Do not infer acceptance merely because one option appears best or has already been implemented. Mark a decision `accepted` when acceptance is established by the user or repository decision record; do not require a redundant confirmation ceremony when the decision has already been made explicitly.

If drafting the ADR exposes an unresolved architectural choice that materially affects the outcome, surface that choice. Do not manufacture certainty just to finish the record.

## Reconcile surrounding authority

Creating or changing an ADR may imply updates elsewhere, but only when the decision actually affects those artifacts:

- If the rationale reveals a normative requirement or invariant, ensure it has an authoritative home in OpenSpec or an appropriate OpenSpec change.
- If the choice settles or changes intended architecture, reconcile the relevant target-architecture section and link the ADR where useful.
- If current Nix disagrees with an accepted direction, treat that as implementation divergence unless evidence shows the architectural decision itself changed.

Reconcile the **relevant architectural neighborhood**. Do not expand an ordinary decision into a repository-wide documentation audit unless its scope warrants that work.

## Confirmation is not an implementation plan

MADR's optional `Confirmation` answers: **How can we tell that the architecture continues to conform to this decision?**

Useful confirmation may be an architectural review, stable Nix evaluation/integration property, policy test, or authoritative OpenSpec verification. Prefer mechanisms that survive ordinary implementation refactors.

Avoid turning Confirmation into a checklist of exact files to edit, commands to run, or rollout tasks to complete.

## Evolving ADRs

### Proposed

A proposed ADR is a working decision document. Revise it as evidence, options, scope, or the proposed outcome evolve. Keep `updated` current for substantive changes.

### Accepted

An accepted ADR preserves the decision and why it was made. It may be edited in place when the edit **does not change the architectural decision it records**.

Reasonable in-place updates include:

- clarifying wording or rationale without changing the choice;
- adding references, confirmation evidence, or later context;
- lifecycle and relationship metadata;
- reciprocal links to later ADRs;
- typo, formatting, or broken-link fixes.

Keep `updated` current for substantive content, lifecycle, or relationship changes. Git history remains useful provenance, but do not rely on Git history alone to represent a changed architectural decision.

If the architectural choice itself changes materially, make that change visible in decision history through a new ADR rather than silently rewriting the accepted decision.

### Rejected

Retain rejected ADRs when they preserve useful analysis. A later reconsideration should normally be a new ADR that cites the earlier record and explains what changed.

### Deprecated

Use `deprecated` when a formerly accepted decision no longer guides new work but there is no complete replacement decision. Existing systems may still embody it. Explain why it ceased to be the preferred direction and link relevant follow-up decisions.

### Modified: partial decision change

Use `modifies` / `modified-by` when a later accepted ADR intentionally changes a **bounded portion** of an accepted decision while the unaffected portion remains applicable.

- The older ADR keeps `status: accepted` and lists the later ADR in `modified-by`.
- The newer ADR lists the older ADR in `modifies` and states the affected scope and resulting decision clearly.
- Reconstruct the current architecture by reading the older decision subject to its accepted modifiers.

`modified` is a relationship, not a lifecycle status. Avoid using it when the later ADR merely adds an orthogonal decision or explanation; use `related-adrs` instead.

Prefer modification relationships only while the effective decision remains easy to reconstruct. If modifications accumulate, overlap, or obscure the current decision, create a consolidating ADR that states the resulting decision cleanly and supersedes the records it replaces.

### Superseded: complete replacement

Reserve `superseded` for a decision that has been **fully replaced**. A superseded ADR no longer contributes an independently active portion of the current architectural decision; it remains historical context.

A replacement may be one successor ADR or, when a broad old decision is deliberately decomposed, several successor ADRs that collectively cover it. Record reciprocal `supersedes` / `superseded-by` relationships.

If any meaningful portion of the old decision is still active, do **not** mark the old ADR superseded merely because another ADR changed part of it; use a scoped modification relationship instead.

## Relationship semantics

Use frontmatter relationships as a navigable decision graph. Relationship fields are **lists**, including when only one ADR is currently linked. This keeps the schema stable and supports legitimate one-to-many and many-to-one evolution.

- `supersedes`: prior ADRs fully replaced by this ADR;
- `superseded-by`: later ADRs that fully replace this ADR, individually or collectively;
- `modifies`: accepted ADRs whose still-active decision is partially changed by this ADR;
- `modified-by`: accepted ADRs that partially change this still-active decision;
- `related-adrs`: meaningful non-replacement/non-modification relationships;
- `related-specs`: relevant accepted OpenSpec authority;
- `related-changes`: relevant active or historical OpenSpec changes;
- `target-architecture`: relevant target-architecture paths or stable anchors.

An empty relationship is `[]`. A single relationship is still represented as a one-item list. Do not alternate between scalar and list forms.

Relationship fields do not transfer authority. A linked requirement remains authoritative in its specification; a linked ADR remains decision history and rationale.

Keep reciprocal `supersedes` / `superseded-by` and `modifies` / `modified-by` metadata consistent in the same change when practical.

## Reconciliation during other work

When planning or implementing an architecture-significant change, inspect relevant ADRs even if the user did not explicitly ask for an ADR.

If proposed work appears to conflict with an accepted ADR, determine whether the conflict is:

- implementation drift while the decision still stands;
- a bounded modification to the decision;
- a complete replacement of the decision;
- or only an apparent conflict caused by scope or stale explanatory detail.

Check target architecture and OpenSpec authority as needed. Surface actual architectural decision changes rather than silently implementing around them.

## Periodic architecture reconciliation

During architecture reconciliation or major planning work, check the relevant architectural neighborhood for:

- accepted ADRs contradicted by newer accepted ADRs without an explicit relationship;
- accepted ADRs materially contradicted by current target architecture;
- target-architecture choices that appear settled but lack durable rationale;
- normative claims present only in ADRs that should have specification authority;
- implementation that no longer conforms to accepted decisions;
- broken reciprocal supersession/modification links;
- modification chains that should be consolidated;
- stale proposed ADRs whose status is no longer truthful.

Do not change decision lifecycle merely because implementation drifted. Lifecycle describes the decision record; implementation conformance is a separate question.

## Standard lineage

The body structure and core terminology are based on **MADR 4.0 (Markdown Architectural Decision Records)**.

The additional machine-readable relationship metadata supports repository-wide architecture reconciliation. Keep MADR's decision-record role intact unless there is a strong reason to evolve it.
