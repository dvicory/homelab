# ADR Template

Use this template for new ADRs. It follows MADR 4.0's full structure while adding machine-readable relationship metadata for architecture reconciliation.

Remove optional body sections that add no value. Keep relationship frontmatter consistent enough for agents and tooling to reconstruct the effective current decision.

```markdown
---
id: ADR-NNNN
status: proposed
date: YYYY-MM-DD
updated: YYYY-MM-DD
decision-makers: []
consulted: []
informed: []
supersedes: []
superseded-by: []
modifies: []
modified-by: []
related-adrs: []
related-specs: []
related-changes: []
target-architecture: []
---

# Short title naming the decision

## Context and Problem Statement

Describe the architectural context, the forces that make a decision necessary, and the decision question.

Summarize authoritative requirements when they are needed to understand the choice, but link to their OpenSpec source rather than redefining them here.

## Decision Drivers

- Driver or constraint that distinguishes between options.
- Desired architectural quality or operational property.
- Cost, security, reversibility, complexity, or migration consideration.

## Considered Options

- Option A
- Option B
- Status quo, if genuinely viable

## Decision Outcome

Chosen option: **Option A**, because it best satisfies the decision drivers while accepting the tradeoffs described below.

If this ADR modifies or supersedes another decision, state the affected scope clearly enough that a reader can reconstruct the resulting current decision.

### Consequences

- Good, because ...
- Bad, because ...
- Neutral, because ...

### Confirmation

Optional. Describe a durable way to determine whether the architecture continues to conform to this decision. Prefer architecture review, stable policy/evaluation properties, or authoritative spec verification over file-level implementation checklists.

## Pros and Cons of the Options

### Option A

Brief description or evidence.

- Good, because ...
- Neutral, because ...
- Bad, because ...

### Option B

Brief description or evidence.

- Good, because ...
- Neutral, because ...
- Bad, because ...

## More Information

### Assumptions

- Assumption that materially affected the decision.

### Reconsideration Triggers

Revisit this decision if one or more of these become true:

- A material assumption changes.
- A rejected option removes the disadvantage that caused it to lose.
- Operational evidence invalidates an important driver or consequence.
- The target architecture or authoritative requirements change enough to reopen the decision.

### References

- Target architecture: `path#section`
- OpenSpec: `spec-id` or path
- Related ADR: `ADR-NNNN`
- External evidence: durable source or short summary
```

## Frontmatter semantics

- `id`: Stable `ADR-NNNN` identifier matching the filename number.
- `status`: Usually `proposed`, `accepted`, `rejected`, `deprecated`, or `superseded`.
- `date`: Date the ADR was first created. Keep this stable.
- `updated`: Date of the latest substantive content, lifecycle, or relationship update. Do not bump for trivial formatting-only edits unless repository convention says otherwise.
- `decision-makers`: People or roles whose decision established acceptance/rejection when useful. Do not invent or hard-code a person when the record does not need it.
- `consulted`, `informed`: MADR/RACI-style context; leave empty when not useful.
- `supersedes`: Prior ADRs fully replaced by this decision.
- `superseded-by`: Later ADRs that fully replace this ADR, individually or collectively. A `superseded` ADR should have no independently active decision scope left.
- `modifies`: Accepted ADRs partially changed by this decision while their unaffected scope remains active.
- `modified-by`: Accepted ADRs that partially change this decision while its unaffected scope remains active.
- `related-adrs`: Meaningful non-supersession/non-modification relationships.
- `related-specs`: Relevant accepted OpenSpec specifications. Prefer stable IDs when available.
- `related-changes`: Relevant OpenSpec change identifiers, active or historical.
- `target-architecture`: Paths and stable section anchors materially related to the choice.

All relationship fields are lists. Use `[]` for none and a one-item list for a single relationship. Do not switch between scalar and list representations; stable shapes are easier for agents and tooling to traverse.

Structured relationship fields are intentionally more precise than embedding successor text inside `status`.

## Complete supersession example

New ADR:

```yaml
id: ADR-0012
status: accepted
supersedes:
  - ADR-0004
superseded-by: []
modifies: []
modified-by: []
```

Old ADR, updated in the same change:

```yaml
id: ADR-0004
status: superseded
supersedes: []
superseded-by:
  - ADR-0012
modifies: []
modified-by: []
```

`ADR-0004` is now historical only; none of its decision remains independently active.

## Partial modification example

Suppose `ADR-0004` chose Incus for both infrastructure guests and Kubernetes workers, and a later decision changes only public Kubernetes workers to another isolation technology.

New ADR:

```yaml
id: ADR-0015
status: accepted
supersedes: []
superseded-by: []
modifies:
  - ADR-0004
modified-by: []
```

Old ADR:

```yaml
id: ADR-0004
status: accepted
supersedes: []
superseded-by: []
modifies: []
modified-by:
  - ADR-0015
```

`ADR-0004` remains part of the current architecture, but its affected scope must be interpreted subject to `ADR-0015`.

If this composition becomes difficult to understand, replace it with a consolidating ADR that states the effective current decision and fully supersedes the records it replaces.

## Editing an accepted ADR

Editing an accepted ADR does not itself require a successor ADR when the underlying architectural choice remains the same. Clarifications, additional references, confirmation evidence, relationship metadata, and similar non-decision changes may be made in place and reflected in `updated`.

If an edit would change what architecture should actually be chosen or where that choice applies, preserve that change in decision history through a new ADR using `modifies` or `supersedes` as appropriate.
