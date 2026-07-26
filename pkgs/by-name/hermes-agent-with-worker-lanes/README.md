# Hermes Agent with worker lanes

This package wraps the Hermes Agent release pinned by the flake and applies
the compatibility patch required by local, out-of-tree Kanban workers.

`worker-lanes.patch` vendors commit
`3461018948b3c603306a37c0e67ea7fd985447c9` from
[JetBrains/hermes-agent#2](https://github.com/JetBrains/hermes-agent/pull/2).
It adds a generic, process-local Kanban worker-lane registry and plugin
registration API. The patch contains no Codex-specific behavior.

The local copy is intentional:

- builds do not depend on the lifetime or state of a fork branch;
- reviewers can see the complete core change in this repository;
- upgrading the pinned Hermes release fails while applying the patch if the
  affected dispatcher contract has drifted; and
- local integrations depend on one documented compatibility boundary.

When updating Hermes:

1. Check whether upstream now exposes an equivalent worker-lane registration
   and dispatch API. Remove this wrapper if it does.
2. Otherwise apply the patch to the new source and run its upstream
   `tests/hermes_cli/test_worker_lanes.py` suite.
3. Run the local `hermes-worker-lane` flake check and the full
   `nix flake check` before deployment.

Do not add Codex prompts, authentication, executable paths, or policy here.
Those belong to the separately packaged `hermes-codex-worker-lane` plugin.
