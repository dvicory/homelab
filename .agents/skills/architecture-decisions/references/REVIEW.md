# ADR Review and Reconciliation

Use this as an adversarial review aid, not as a mandatory ceremony. Apply the checks that matter to the decision's scope.

## Decision quality

- Is the decision question and scope understandable without relying on current file layout?
- Are tightly coupled concerns kept together and independently evolvable choices separated where useful?
- Are the real decision drivers stated rather than reconstructed from the preferred option?
- Are credible alternatives represented fairly?
- Does the outcome explain why the selected option wins against those drivers?
- Are meaningful negative and neutral consequences preserved?
- Are assumptions explicit enough that later evidence could reopen the decision?
- Are reconsideration triggers useful rather than boilerplate?

## Authority hygiene

- Does the ADR preserve decision rationale rather than becoming a second specification?
- If it summarizes a requirement, does it point to the authoritative OpenSpec source rather than redefine it?
- Is an active OpenSpec change being mistaken for accepted authority?
- Is current Nix/configuration being mistaken for architectural intent?
- If the decision changes intended direction, is the relevant target architecture reconciled?
- Are implementation details included only when they are architecturally significant?

## Lifecycle and relationship integrity

- Is `status` truthful based on established decisions rather than inferred preference or implementation?
- Are `date` and `updated` meaningful and non-conflicting?
- Are rejected alternatives retained when they provide future value?
- If another ADR fully replaces this decision, is `superseded` appropriate because no meaningful decision scope remains independently active?
- If only a bounded portion changes, should this instead use reciprocal `modifies` / `modified-by` while the older ADR remains accepted?
- If the new decision is merely additive or orthogonal, should it only use `related-adrs`?
- Are all relationship fields consistently represented as lists, including one-item relationships?
- Are replacement/modification relationships reciprocal and their scopes understandable?
- Has a modification chain become complex enough that a consolidating ADR would be clearer?

The goal is not to minimize the number of relationship types. The goal is that a future agent can reconstruct the **effective current decision** without guessing.

## In-place edit versus new decision

For an accepted ADR, ask:

- Does this edit merely clarify, add evidence/references, or improve the record without changing the architectural choice? If so, an in-place edit with `updated` is appropriate.
- Would the edit change what should be chosen, where it applies, or a material consequence of the choice? If so, preserve the decision change in a new ADR.
- Is the changed scope bounded while the rest remains active? Use `modifies` / `modified-by`.
- Is the prior decision fully replaced? Use `supersedes` / `superseded-by` and mark the old ADR `superseded`.

Do not create successor ADRs for documentation churn, and do not hide actual decision changes inside ordinary edits.

## Confirmation quality

When Confirmation is useful:

- Does it test continuing architectural conformance rather than implementation completion?
- Would it remain meaningful after ordinary Nix/module refactors?
- Can an existing policy test, integration property, architectural review, or OpenSpec verification express it more durably?

Omit Confirmation when it would add only ceremonial or brittle detail.

## Reconciliation scope

- Have the relevant target architecture, specs, ADR history, and current implementation been considered where they matter?
- Has the review avoided expanding a local decision into a repository-wide audit without reason?
- Is an implementation divergence being incorrectly treated as a decision change, or vice versa?

## Adversarial pass

Try to falsify the draft where useful:

- What evidence would make a rejected option preferable?
- Is the chosen option benefiting mainly from implementation familiarity?
- Are current limitations being treated as permanent constraints without evidence?
- Is a requirement being invented to justify the preferred option?
- Would a future agent mistake incidental implementation detail for a durable decision?
- Does the choice create a security, trust, data, operational, migration, or reversibility commitment that has not been considered?
- Could the same result be recorded more clearly by changing scope rather than adding a complicated modification/supersession graph?

Surface unresolved consequential choices. Do not manufacture certainty merely to produce a clean ADR.
