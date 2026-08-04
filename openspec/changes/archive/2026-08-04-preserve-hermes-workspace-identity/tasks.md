## 1. Contract and identity

- [x] 1.1 Define the stable compression-only workspace owner, non-export requirement, `/resume` and compression continuity, `/new` and delegate isolation, and private `/branch` inheritance.
- [x] 1.2 Add focused Hermes regressions for cross-route resume, compression, `/new`, branch identity, delegate isolation, lineage-read failure, and absence from subprocess environments.

## 2. Hermes lifecycle integration

- [x] 2.1 Add a private task-local workspace-owner context field and bind it from persisted compression lineage before model tools execute.
- [x] 2.2 Route every conversation environment-backed surface through that owner while leaving approval delivery on the gateway key.
- [x] 2.3 Add a required broker-backed branch-preparation lifecycle contract; block route switching and remove or hide provisional branch state on failure.
- [x] 2.4 Make the sandbox lifecycle plugin restore authority before every model tool call and prepare private branches idempotently.

## 3. Broker private branch copy

- [x] 3.1 Add strict branch-preparation request, response, error, authorization, journal, and destination-uniqueness schemas on the control socket only.
- [x] 3.2 Serialize with environment mutation; close and drain the parent VM, copy the complete workspace through detached temporary storage, and atomically install a private child workspace and lease.
- [x] 3.3 Cover empty parents, copy divergence, source mutation fencing, identical replay, changed-fact conflict, failure cleanup, restart recovery, and independent parent/child mutation.

## 4. Verification and deployment

- [x] 4.1 Regenerate the ordered Hermes patch from the exact upgraded predecessor and run focused Python/plugin checks.
- [x] 4.2 Run the Gondolin broker package tests, patched Hermes check, secure-terminal Nix checks, and repository flake check.
- [x] 4.3 Deploy QA only; verify write → `/new` → `/resume`, compression continuation, private `/branch` divergence, cross-gateway resume, and restart recovery.
