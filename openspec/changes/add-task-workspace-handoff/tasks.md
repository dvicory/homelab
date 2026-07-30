> Prerequisites: `add-sandbox-workspace-service` is archived. Complete `add-explicit-worker-lanes` before changing the remaining activation/finalization schemas so every route binds one frozen worker identity.

## 1. Broker immutable-output foundation

- [x] 1.1 Extract repeated SQLite connection, schema-migration, and transaction setup into one shared broker database service without behavior changes.
- [x] 1.2 Preserve task-run activation persistence and validation on every ensure/execution/file route so completed, superseded, blocked, reclaimed, and stale runs cannot recreate or borrow another generation.
- [x] 1.3 Replace partial path-publication records with handoff records and a finalization journal bound to board/task/run/lane, optional Project/source generation, workspace/lease, policy, fixed `/workspace/output`, and the ordered selected-artifact set.
- [x] 1.4 Implement one capture operation accepting exactly `finalizationId`, trusted `environmentKey`, `taskId`, `runId`, and `selectedArtifacts`: preflight while active, consume/fence, revoke the writer, close/drain the VM, copy to broker-owned temporary storage, fsync, and atomically install one immutable handoff and selected-artifact manifest.
- [x] 1.5 Implement live and detached structural validation with exactly `maxLogicalBytes`, `maxEntries`, `maxFileBytes`, and `maxPathBytes`; reject traversal, malformed or colliding names, symlinks, disallowed hardlinks, special files, unreadable entries, filesystem crossings, invalid selected artifacts, and limit excess without content scanning or silent deletion.
- [x] 1.6 Make identical finalization replay resume or return one operation after fencing, reject changed facts, reconcile every journal state after restart, and require fresh run/finalization IDs for deliberate retries.
- [x] 1.7 Add the local control-UDS `artifacts/read` operation accepting exactly hidden `handoffId` and normalized `relativePath`; serve only manifest-selected frozen regular files and expose no listing, live-workspace fallback, broker path, or shared spool.
- [x] 1.8 Ensure completion, block, timeout, and reclaim consume or supersede the active run before VM close; late old-run operations fail and reclaim captures or delivers nothing.

## 2. Hermes completion and delivery slice

- [x] 2.1 Send syntax-validated broker-worker artifact paths in the single capture request, keep summary/result prose non-authoritative, accept an empty handoff, and keep Kanban `running` until a ready handoff, verified selected-artifact manifest, and durable native task attachments for every selected file exist.
- [x] 2.2 Keep capture/finalization and native attachment materialization failure-propagating under existing Kanban states while native scratch/dir/worktree completion continues to materialize selected files before `done`.
- [x] 2.3 Read each frozen selected artifact over the local control UDS into upstream native task attachment storage exactly once before `done`, independent of recipient subscriptions; make ordinary task attachment inspection expose it; persist recipient/attachment delivery stages, retry only outstanding deliveries, and never advance the completion-event cursor on failed upload.
- [x] 2.4 Extend the repository workspace-service bridge and Gondolin backend to attach frozen worker/run identity, activate/fence runs, invoke capture and selected-artifact read, recover capture and materialization in process, and fail closed without host/local/Docker/Podman fallback.
- [x] 2.5 Delete `inherit_parent_output`, writable child-import routes and persistence, direct-child preparation, related prompts/tests, and compatibility behavior before declaring this workstream complete.
- [x] 2.6 Extend existing attachment inspection with an explicit completed-task delivery action that resolves durable native attachments only inside the gateway, exposes no host path, and creates no attachment row or byte copy.
- [x] 2.7 Make live orchestration push-driven: prefer durable Kanban work for requested downloads, stop status polling after creation, prohibit recreation/manual upload of broker-selected files, and reject duplicate completed-handoff uploads.

## 3. Integration and verification

- [x] 3.1 Wire broker-owned handoff storage, the four structural limits, journal recovery, policy actions, service hardening, protected local control UDS, and the explicit handoff gate through the secure-terminal module.
- [x] 3.2 With the gate disabled, assert activation, capture, selected-artifact read, handoff schema/root, and policy actions are absent while ordinary workspace behavior remains unchanged.
- [x] 3.3 Exercise empty and non-empty capture; selected and unselected paths; syntax and structural rejection; response loss before/after fencing; post-fence recovery; all four limits; replay conflicts; stale-run rejection; block/reclaim races; interrupted local reads; partial recipient failure; cursor retry; and broker outage/recovery.
- [x] 3.4 Record broker-derived evidence without claiming a new Kanban task state, content scanning, unsupported limits, exactly-once platform delivery, or information-flow isolation.
