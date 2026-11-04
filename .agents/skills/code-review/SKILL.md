---
name: code-review
description: Use when reviewing a diff, pull request, or review feedback for substantive correctness, security, contract, test-quality, and maintainability issues. Ground findings in actual behavior and project authority, not superficial checklists.
---

# Code review

Review the change that exists, against the behavior it promises. Prefer a few consequential, evidenced findings to a long list of smells. This skill supplies a review method, not new project policy; follow the repository's actual contracts and the requested review scope.

## Establish the review frame

Read the purpose, base revision, complete diff and relevant project guidance. Introduce the encompassing problem and intended outcome before implementation details. Identify what changes, what stays supported, and what is deliberately outside scope. If intent or authority is disputed, name the specific uncertainty rather than inventing a requirement.

Treat prior reviews as leads. Check their revision, assumptions and resolution before repeating them. Reviewer agreement, a green check, a signature, or code already on main does not establish correctness or authorization. A security-sensitive configuration deserves scrutiny but does not automatically require a new specification.

## Trace behavior, not labels

Follow affected callers and production composition from input to observable outcome. Read the shared API as well as its CLI/UI wrapper, generated configuration and runtime consumers. For stateful or privileged changes, trace the relevant lifecycle: initialization, normal use, failure/cancellation, restart, replacement and cleanup.

Look for concrete mismatches:

- Authority checks and required safety evidence precede side effects at a boundary shared by every entry point; declared permission is not replaced by a component's self-reported capability.
- Persisted receipts, paths and other previously accepted inputs are revalidated where current authorization requires it. Filtered or enabled-only inventories do not silently omit live state that still needs protection.
- Identity, login eligibility and administrative privilege remain distinct. Secrets and sensitive state do not leak through output, logs, generated files or error handling.
- Failures preserve required state and report the actual problem instead of bypassing a guard, swallowing an error, or patching around a missing operator decision. Unknown, unavailable and absent are not interchangeable.

These are investigation prompts, not a demand to add mechanisms everywhere. Establish the actual trust boundary and failure path before reporting a vulnerability; intended operator/root powers are not themselves a new exposure.

## Ask what the tests prove

For each changed or relied-upon test, identify its claimed behavior and a plausible broken implementation that should fail it. Check the assertion, independent oracle and exercised production path—not merely that a command ran, evidence was recorded, a literal is present or a mock was called.

Where relevant, inspect rejection, authorization, recovery and cleanup cases. Expected-failure checks must distinguish the intended refusal from unrelated errors. Fixtures may substitute external dependencies, but must not manufacture the outcome or bypass the composition under test. Permissive fakes can hide real parser/API drift; use real-boundary checks safely, with destructive behavior confined to isolated disposable fixtures, never production or user state.

For supported weak or redundant coverage findings, recommend **DELETE, MERGE or STRENGTHEN**; retain useful coverage without narrating routine KEEP decisions. Every retained test should detect a distinct plausible regression; do not replace redundant tests automatically. Prefer the smallest appropriate layer that proves the contract. Expensive integration coverage can be necessary, while a unit/evaluation test can be sufficient. Choose hermetic fixtures versus live dependencies deliberately; neither is universally superior.

When coverage is moved, split or rebased, map the old semantic claims—including additions since the branch diverged—to retained coverage. Fewer tests or green CI is not evidence that the concepts survived.

## Review ownership and reader value

Reuse established architecture, standard platform mechanisms and existing libraries before custom wrappers or parallel sources of truth. Ask what responsibility each abstraction uniquely owns and whether a simpler existing mechanism preserves the capability. Flag concrete coupling, duplicate authority or unnecessary maintenance—not file size, language choice, naming or line count alone. Do not delete useful integration seams or migrate languages just to make the diff smaller.

For cutovers, check callers, retained behavior, contracts and documentation together. Remove obsolete intermediate machinery, but preserve meaningful concepts and rationale. Commit boundaries should express logical changes, not every repair round or one giant squash by default.

Durable documentation should serve its actual reader: supported procedures, prerequisites, safety boundaries and limitations belong in operations docs; temporary branches, incident chronology and agent progress usually do not. PR descriptions should explain purpose, outcome, scope and important tradeoffs before component details, adding context unavailable from the diff or commit list. Presentation preferences are not correctness blockers unless they create a concrete operational risk.

## Report findings

Separate **correctness/security/contract risks** from **maintainability** and optional **presentation** observations. Rank by demonstrated impact, not the review tool's label. For each finding provide:

- **Location:** file/line or precise interface at the reviewed revision.
- **Failure and impact:** triggering conditions, expected versus actual behavior, and who or what is affected.
- **Evidence:** caller/contract/source trace or exercised check; distinguish observation from inference.
- **Smallest useful action:** fix, delete, merge, strengthen, or a specific decision/question when evidence is incomplete.

For weak-test findings, include the plausible defect that still passes and stronger coverage that already subsumes the test, if any. Omit generic advice, restated code, speculative future requirements and already-resolved findings. A pin/default/style observation needs a contract or failure consequence to become a substantive finding.

Close with a short scope/coverage summary and remaining uncertainty. Report only checks actually exercised; do not imply unrun tests passed. “No substantive findings” is a valid result, not a reason to manufacture comments. Review does not itself authorize edits, deployment or merging.
