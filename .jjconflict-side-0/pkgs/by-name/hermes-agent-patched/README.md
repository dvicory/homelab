# Locally patched Hermes Agent

This package wraps the Hermes Agent release pinned by the flake and applies
the small upstream compatibility patches required by this deployment. Keep
features generic and independently reviewable: each patch should have its own
tests and should be removed when the pinned release provides the capability.

## Worker lanes

`worker-lanes.patch` vendors commit
`3461018948b3c603306a37c0e67ea7fd985447c9` from
[JetBrains/hermes-agent#2](https://github.com/JetBrains/hermes-agent/pull/2).
It adds a generic, process-local Kanban worker-lane registry and plugin
registration API. The patch contains no Codex-specific behavior.

## Secure terminal isolation

`secure-terminal-isolation.patch` adds deployment-selectable conversation keys,
engine-owned named volumes, and suppression of gateway-side support-file bind
mounts for a remote Docker-compatible engine. The small follow-up handler patch
passes the trusted session identity into the terminal path. Nix keeps these
controls operator-owned through environment variables; they are not model tool
arguments.

The NixOS side of the boundary lives in the Hermes account aspect, which creates
the dedicated rootless Podman account and systemd-activated capability socket.
See `HERMES_NIX_SECURE_TERMINAL_BACKEND.md` for the threat model and remaining
QA gaps.

The local copy is intentional:

- builds do not depend on the lifetime or state of a fork branch;
- reviewers can see the complete core change in this repository;
- upgrading the pinned Hermes release fails while applying the patch if the
  affected dispatcher contract has drifted; and
- local integrations depend on one documented compatibility boundary.

When updating Hermes:

1. Check whether upstream now exposes an equivalent worker-lane registration
   and dispatch API. Remove this wrapper if it does.
2. Otherwise apply the ordered patch stack to the new source and run its
   worker-lane and secure-terminal test suites.
3. Run the local `hermes-worker-lane` flake check and the full
   `nix flake check` before deployment.

Do not add Codex prompts, authentication, executable paths, or policy here.
Those belong to the separately packaged `hermes-codex-worker-lane` plugin.
