## 1. Implement the narrow source-error boundary

- [x] 1.1 Make the existing Application health customization prioritize explicit ComparisonError over child health; execute the rendered Lua to verify error precedence, absent health, unrelated conditions, ordinary OutOfSync and recovery after error removal.
- [x] 1.2 Regenerate canonical manifests with the existing writer and update operator guidance; verify exact-revision freshness and that the rendered Application health customization is the intended production delta.

## 2. Prove parent blocking and recovery

- [ ] 2.1 Integrate the isolated health revision with the focused Argo fixture and extend its missing-source case to restore the source; prove the real controller blocks the later wave while the error exists and completes it after current-revision recovery without a manual health bypass.
- [ ] 2.2 Remove the source-error guard in a disposable counterfactual and verify the same controller scenario fails because the later wave advances prematurely; preserve sanitized outcomes and exact source identities.

## 3. Prepare operator review

- [ ] 3.1 Validate this OpenSpec change and reconcile its dependency with the separate CI migration; confirm the migration does not silently own this production behavior.
- [ ] 3.2 Publish a draft review on an unwatched branch with measured evidence, rollout limitations and the no-merge/no-deployment boundary; verify the PR selects the intended revisions.
