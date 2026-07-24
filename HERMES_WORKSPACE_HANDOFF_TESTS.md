# Hermes workspace handoff: QA deployment and test guide

This guide deploys and exercises the workspace-handoff change on `hvn-hyp1`
QA only. It does **not** authorize or describe a production Hermes promotion.
The change has not been deployed as part of its implementation.

## Scope and required order

Two independently activated artifacts changed:

1. **`hvn-hyp1` NixOS configuration**: the QA broker package, rendered
   `workspace.publish`/`workspace.import` policy, revision limits, broker gate,
   and systemd hardening.
2. **`hermes-qa-runner@hvn-hyp1` Home Manager generation and QA OCI image**:
   the trusted workspace-service bridge, task/run propagation, required
   completion finalizer, dispatcher preparation, and
   `HERMES_WORKSPACE_HANDOFF=1`.

Deploy the host first, then QA Hermes. A new gateway against an old broker fails
closed on handoff operations; the reverse order leaves the old gateway behavior
unchanged while the broker waits for trusted handoff requests. Do not run the
`hermes-deploy` QA-to-production workflow for this test: that workflow promotes
the same revision to production after its QA canary.

Use one reviewed, pushed commit for both artifacts. Tracked deployment inputs
must match that commit:

```sh
REVISION=$(git rev-parse HEAD)
printf 'Testing revision %s\n' "$REVISION"
git diff --exit-code
git diff --cached --exit-code
git status --short
```

Stop if either diff is non-empty or if the reviewed revision differs from the
one that will be deployed. Pre-existing untracked notes are not flake inputs
and need not be removed, but no untracked file may be required by this
deployment.

## 1. Pre-deployment checks

From the repository root on the workstation:

```sh
openspec validate add-task-workspace-handoff --strict
nix eval .#nixosConfigurations.hvn-hyp1.config.system.build.toplevel.drvPath --raw
nix build --no-link \
  .#checks.aarch64-darwin.gondolin-broker-effect \
  .#checks.aarch64-darwin.hermes-worker-lane \
  .#checks.aarch64-darwin.secure-terminal-effect-policy-http \
  .#checks.aarch64-darwin.secure-terminal-socket-directory-mount
```

Capture the production service timestamp before touching QA:

```sh
SSH_OPTS=(-o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=modules/den/hosts/hvn-hyp1/known_hosts)
ssh "${SSH_OPTS[@]}" -t daniel@172.27.50.17 \
  'sudo systemctl --machine=hermes-prod-runner@ --user show hermes-prod.service \
    -p ActiveState -p ActiveEnterTimestampMonotonic'
```

Also capture QA state:

```sh
ssh "${SSH_OPTS[@]}" -t daniel@172.27.50.17 \
  'sudo systemctl is-active hermes-qa-broker.service \
    hermes-qa-broker-execution.socket hermes-qa-broker-control.socket; \
   sudo systemctl --machine=hermes-qa-runner@ --user is-active hermes-qa.service'
```

## 2. Deploy the `hvn-hyp1` host configuration

This activates the NixOS configuration for one host. Review all changes relative
to that host's deployed revision first; a NixOS activation is host-wide even
though this change is QA-scoped.

```sh
nix run .#deploy-rs -- .#hvn-hyp1
```

After activation, verify the QA broker units and rendered gate:

```sh
ssh "${SSH_OPTS[@]}" -t daniel@172.27.50.17 <<'REMOTE'
set -eu
sudo systemctl is-active \
  hermes-qa-broker-execution.socket \
  hermes-qa-broker-control.socket
sudo systemctl show hermes-qa-broker.service \
  -p User -p Group -p Environment \
  -p ProtectControlGroups -p DevicePolicy -p DeviceAllow \
  -p CapabilityBoundingSet -p RestrictSUIDSGID
sudo -u hermes-qa-runner curl --fail --silent --show-error \
  --unix-socket /run/hermes-qa-broker/broker.sock \
  http://localhost/v1/health
sudo -u hermes-qa-runner curl --fail --silent --show-error \
  --unix-socket /run/hermes-qa-broker/control.sock \
  http://localhost/v1/health
REMOTE
```

Expected facts:

- `User=hermes-qa-sandbox` and `Group=hermes-qa-sandbox`;
- `GONDOLIN_EFFECT_STATE_DIR=/var/lib/hermes-qa-sandbox`;
- `GONDOLIN_EFFECT_WORKSPACE_HANDOFF=true`;
- `ProtectControlGroups=yes`, `DevicePolicy=closed`, and only `/dev/kvm rw`
  is added to the standard closed device set;
- execution and control health identify their respective planes.

Revision content is derived by the broker at
`/var/lib/hermes-qa-sandbox/workspace-revisions`; there is no independently
configurable revision root.

## 3. Deploy only the QA Hermes image and Home Manager generation

Build both Linux artifacts on the workstation:

```sh
QA_IMAGE=$(nix build --no-link --print-out-paths \
  '.#packages.x86_64-linux.hermes-agent-image')
QA_HOME=$(nix build --no-link --print-out-paths \
  '.#homeConfigurations."hermes-qa-runner@hvn-hyp1".activationPackage')
printf 'QA image: %s\nQA Home generation: %s\n' "$QA_IMAGE" "$QA_HOME"
```

Copy their closures to `hvn-hyp1`:

```sh
export NIX_SSHOPTS="-o StrictHostKeyChecking=yes \
-o UserKnownHostsFile=$PWD/modules/den/hosts/hvn-hyp1/known_hosts"
nix copy --to ssh-ng://daniel@172.27.50.17 "$QA_IMAGE" "$QA_HOME"
```

Activate only the QA account. The profile update makes rollback deterministic;
the activation script updates Quadlet and user-systemd state. Enter sudo
credentials when prompted.

```sh
ssh "${SSH_OPTS[@]}" -t daniel@172.27.50.17 \
  "sudo bash -s -- '$QA_IMAGE' '$QA_HOME'" <<'REMOTE'
set -euo pipefail
image=$1
generation=$2
user=hermes-qa-runner
uid=$(id -u "$user")

run_qa() {
  runuser --user "$user" --preserve-environment -- env \
    HOME="/home/$user" \
    USER="$user" \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    PATH="/etc/profiles/per-user/$user/bin:/run/current-system/sw/bin" \
    "$@"
}

run_qa podman load --input "$image"
run_qa nix-env \
  --profile "/nix/var/nix/profiles/per-user/$user/home-manager" \
  --set "$generation"
run_qa "$generation/activate"
systemctl --machine="$user@" --user restart hermes-qa.service
systemctl --machine="$user@" --user is-active hermes-qa.service
REMOTE
```

Verify the running QA container, without printing secrets:

```sh
ssh "${SSH_OPTS[@]}" -t daniel@172.27.50.17 <<'REMOTE'
set -eu
qa_podman() {
  sudo -u hermes-qa-runner env \
    HOME=/home/hermes-qa-runner \
    XDG_RUNTIME_DIR=/run/user/1100 \
    podman "$@"
}
container=$(qa_podman ps \
  --filter 'label=PODMAN_SYSTEMD_UNIT=hermes-qa.service' \
  --format '{{.ID}}')
if [ -z "$container" ]; then
  container=$(qa_podman ps --filter name=hermes-qa --format '{{.ID}}')
fi
test -n "$container"
qa_podman inspect "$container" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E '^(HERMES_WORKSPACE_HANDOFF=1|HERMES_GONDOLIN_SOCKET=|GONDOLIN_EFFECT_CONTROL_SOCKET=|TERMINAL_ISOLATION_SCOPE=)'
sudo systemctl --machine=hermes-qa-runner@ --user is-active hermes-qa.service
REMOTE
```

Do not load the image into `hermes-prod-runner`, do not switch
`hermes-prod-runner@hvn-hyp1`, and do not restart `hermes-prod.service`.

## 4. Hermes-agent prompt tests

Use a fresh QA chat/session. Record the exact prompts, task IDs, timestamps, and
Hermes responses. Unique markers prevent old state from producing false passes.
Replace every `HANDOFF-YYYYMMDD-HHMMSS` below with one new marker.

### 4.1 Normal conversation regression

Send this outside a Kanban worker:

> Use the terminal, not Kanban, to create `/workspace/conversation-check.txt`
> containing exactly `HANDOFF-YYYYMMDD-HHMMSS-CONVERSATION`, then read it back.
> Report the exact text and whether the command exited successfully. Do not
> request sandbox access and do not create a task.

Pass: terminal execution succeeds through the ordinary conversation environment.
No task-run or revision metadata appears in the answer.

### 4.2 Ordinary no-output Kanban completion

> Create one Kanban task assigned to `codex` titled
> `handoff ordinary HANDOFF-YYYYMMDD-HHMMSS`. Its body must tell the worker to
> create `/workspace/ordinary.txt` containing
> `HANDOFF-YYYYMMDD-HHMMSS-ORDINARY`, read it back, and call
> `kanban_complete` normally **without** `workspace_outputs`. Do not create a
> child. Track the task until it is done and report its final status.

Pass: the task reaches `done`. The broker consumes/fences the run even though no
revision is published. Ordinary completion text contains no revision ID,
manifest digest, workspace ID, lease ID, or host path.

### 4.3 Selected parent output and one private child import

> Create one Kanban task assigned to `codex` titled
> `handoff parent HANDOFF-YYYYMMDD-HHMMSS`. Give it this exact work plan:
>
> 1. In `/workspace`, create `output/selected.txt` containing
>    `HANDOFF-YYYYMMDD-HHMMSS-PARENT` and create `not-selected.txt` containing
>    `MUST-NOT-BE-INHERITED`.
> 2. Read both files back.
> 3. Create exactly one direct child assigned to `codex`, with
>    `inherit_parent_workspace_output: true`. Do not supply any source task,
>    workspace, lease, revision, storage, host path, destination, mapping, or
>    second input. The child body is: verify `output/selected.txt` contains the
>    parent marker; verify `not-selected.txt` does not exist; append
>    `-CHILD-MUTATION` to `output/selected.txt`; create `output/child.txt`
>    containing `HANDOFF-YYYYMMDD-HHMMSS-CHILD`; then complete with
>    `workspace_outputs: ["output"]`.
> 4. Complete the parent with `workspace_outputs: ["output"]`.
>
> Track parent and child until both are done. Report their task IDs, statuses,
> and the child-observed file contents. Do not report internal storage metadata.

Pass:

- exactly one child runs after the parent is done;
- the child sees `output/selected.txt`, not `not-selected.txt`;
- child mutation does not alter the parent's immutable published revision;
- both completions are `done`;
- ordinary task context and replies omit revision/manifest/workspace/lease IDs
  and host paths.

### 4.4 Same-task retry retains bytes and supersedes the old run

First send:

> Create one Kanban task assigned to `codex` titled
> `handoff retry HANDOFF-YYYYMMDD-HHMMSS`. Its instructions are: if
> `/workspace/retry-marker.txt` does not exist, create it with exactly
> `HANDOFF-YYYYMMDD-HHMMSS-FIRST-RUN`, read it back, then call
> `kanban_blocked` with reason `intentional handoff retry checkpoint` and do not
> complete. If the file already exists, read and report its exact existing
> value, append `-SECOND-RUN`, and complete with
> `workspace_outputs: ["retry-marker.txt"]`. Report the task ID after its first
> blocked transition.

After it is visibly blocked, send:

> Unblock the task `<TASK_ID>` from the intentional retry test. Do not create a
> replacement task. Track the same task through its next run and report whether
> it observed the first-run marker before appending the second-run marker.

Pass: the same task gets a newer run, observes retained bytes, and completes.
The prior run cannot execute or publish after supersession.

### 4.5 Unsafe node rejection

> Create one Kanban task assigned to `codex` titled
> `handoff symlink rejection HANDOFF-YYYYMMDD-HHMMSS`. Tell it to create
> `/workspace/output/real.txt`, create a symbolic link
> `/workspace/output/link.txt` pointing to `real.txt`, and attempt completion
> with `workspace_outputs: ["output"]`. It must report the exact completion
> error and task status; it must not delete the link or retry with a different
> selection.

Pass: publication rejects the symlink, completion does not claim `done`, and no
ready revision is exposed.

### 4.6 File-size limit rejection

> Create one Kanban task assigned to `codex` titled
> `handoff size rejection HANDOFF-YYYYMMDD-HHMMSS`. Tell it to run
> `truncate -s 16777217 /workspace/too-large.bin`, verify that exact logical
> size with `stat`, and attempt completion with
> `workspace_outputs: ["too-large.bin"]`. It must report the exact completion
> error and task status and must not shrink or replace the file.

Pass: the 16 MiB per-file ceiling rejects publication and the task does not
claim `done`.

### 4.7 Fail-closed broker outage and replay

Create a producer with a deliberate delay before its one completion attempt:

> Create one Kanban task assigned to `codex` titled
> `handoff outage HANDOFF-YYYYMMDD-HHMMSS`. Tell it to create
> `/workspace/outage.txt` with `HANDOFF-YYYYMMDD-HHMMSS-OUTAGE`, verify it,
> sleep for 120 seconds, then attempt `kanban_complete` exactly once with
> `workspace_outputs: ["outage.txt"]`. If completion fails, it must report the
> exact error and stop without rerunning commands, changing the selection, or
> blocking the task. Report the task ID as soon as it has been created.

Stop only the QA broker and its two sockets:

```sh
ssh "${SSH_OPTS[@]}" -t daniel@172.27.50.17 \
  'sudo systemctl stop hermes-qa-broker-execution.socket \
    hermes-qa-broker-control.socket hermes-qa-broker.service'
```

Stop the QA broker during the 120-second delay. Wait until the worker's single
completion attempt has failed. Pass at this stage: the task does not become
`done`, and no host workspace fallback is used. Restore QA:

```sh
ssh "${SSH_OPTS[@]}" -t daniel@172.27.50.17 \
  'sudo systemctl start hermes-qa-broker-execution.socket \
    hermes-qa-broker-control.socket'
```

Allow one dispatcher tick or ask QA Hermes to show the task again. Pass: the
persisted finalization ID replays, the broker returns the same publication, and
the task reaches `done` without rerunning producer commands.

## 5. Operator evidence after prompts

The model-facing tools intentionally cannot prove storage and fencing facts.
Collect these from the QA broker while keeping opaque IDs out of normal chat.
Do not paste database output back into Hermes.

```sh
ssh "${SSH_OPTS[@]}" -t daniel@172.27.50.17 <<'REMOTE'
set -eu
sudo systemctl is-active hermes-qa-broker.service \
  hermes-qa-broker-execution.socket hermes-qa-broker-control.socket
sudo du -sh /var/lib/hermes-qa-sandbox/workspace-revisions
sudo find /var/lib/hermes-qa-sandbox/workspace-revisions -xdev -maxdepth 2 \
  -type d -printf '%m %u:%g %p\n' | sort
sudo journalctl -u hermes-qa-broker.service --since '2 hours ago' \
  --grep='workspace\|revision\|task.run' --no-pager
REMOTE
```

Run the production timestamp check again. Pass: `hermes-prod.service` remains
active and `ActiveEnterTimestampMonotonic` is unchanged.

The repository checks cover duplicate/conflicting operation IDs,
forged/unrelated task bindings, cross-board/tenant rejection, stale runs,
tampered revision content, restart/reconciliation, path normalization,
unsupported nodes, and all numeric limits. Conversational prompts cannot safely
forge those trusted-only fields. Do not claim the full OpenSpec QA acceptance
from prompts alone: retain the focused Nix check outputs and broker-derived
host evidence alongside the prompt transcript.

## 6. Rollback and destructive QA reset

### Normal rollback

1. Stop `hermes-qa.service` only.
2. Restore the preceding QA Home Manager profile generation and activate it.
3. Restore the preceding `hvn-hyp1` NixOS generation, or disable
   `secureTerminal.workspaceHandoff.enable` and deploy that reviewed host
   configuration.
4. Restart the QA broker sockets, then QA Hermes.
5. Verify the production service timestamp is unchanged.

A disabled broker does not install revision routes or open revision storage;
retaining QA state for diagnosis is safe.

### Destructive QA reset

There is no revision deletion/retention API in this increment. Do not delete
`workspace-revisions` alone and do not edit `broker.sqlite`: activation,
workspace, revision, and import rows are linked.

Stop the QA gateway, both QA broker sockets, and the QA broker service. Resolve
and verify the target is exactly beneath `/var/lib/hermes-qa-sandbox`, and is
neither `/var/lib/hermes-prod-sandbox` nor any Podman storage path. Move the
entire QA broker state directory to an operator-named quarantine on the same
filesystem. Restart the sockets so systemd recreates the empty `StateDirectory`
with mode `0700`, then start QA Hermes. Delete the quarantine only after fresh
QA broker health, a fresh workspace, and unchanged production state are
observed.
