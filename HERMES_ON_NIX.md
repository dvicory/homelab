# Hermes Agent on Nix — Self-Modifying MicroVM Architecture

## Status

Planning document. Implementation has not started. This plan is for a future
agent (or human) to execute against.

## Goal

Run Hermes Agent in native Nix mode inside MicroVMs on hvn-hyp1, with the
ability to self-modify its own infrastructure through git PRs. Two
environments: QA and prod. Deploys are decoupled from the host and from
GitHub Actions. No third-party SSH access.

## Current state

- Hermes Agent runs in a NixOS systemd-nspawn container on hvn-hyp1
  (`modules/den/aspects/services/hermes.nix`)
- Pinned to hermes-agent rev `6dfb832` (last working Nix build before
  NousResearch dropped Nix support — see GitHub issue #52919)
- Tailscale is enabled on hvn-hyp1 (with `authKeyFile` via agenix —
  assumed to be in place by the time this plan is implemented)
- Telegram messaging is configured via the `messaging` dependency group
- deploy-rs is the host deployment tool (`modules/flake/deploy-rs.nix`)
- No CI exists (no `.github/workflows/`, no checks)
- No microvm.nix in the repo yet (UID 653 reserved in deterministic-uids.nix)

## Prerequisites

These must be completed before starting the implementation phases. Some
are external to the repo (Tailscale admin console, GitHub repo settings),
some are repo-level (deploying the current nspawn setup).

### 1. Verify nspawn Hermes is running on hvn-hyp1 (DONE)

The current nspawn-based hermes setup (committed, pinned to
`v2026.6.19` with nixpkgs follow) is deployed and the agent is running.
This is the foundation the MicroVM plan migrates from. The nspawn
container will be removed in Phase 4 after the prod MicroVM is verified.

### 2. Tailscale authKeyFile for headless VM auth (DONE)

The tailscale aspect (`modules/den/aspects/core/network/tailscale.nix`)
now supports `authKeyFile` via a shared reusable key at
`.secrets/shared/tailscale-auth-key.age`. The aspect is backwards-
compatible — `authKeyFile` is only set when the secret file exists, so
existing hosts keep interactive auth until the key is provisioned.

A single key is shared across all hosts (not per-VM). The 90-day key
expiry only matters for first boot of a new node; after that,
`/var/lib/tailscale` (persisted) holds the identity indefinitely.

### 3. Tailscale Funnel on hvn-hyp1

The webhook receiver needs a public HTTPS endpoint. Tailscale Funnel
provides this without exposing other ports.

**What to do**:
- In the Tailscale admin console, enable Funnel on hvn-hyp1's node
  (`tailscale funnel on` from the node, or via admin console)
- This is a per-node setting, not a tailnet-wide setting

### 4. GitHub repo configuration

The trust model depends on branch protection preventing the agent from
pushing directly to `main`.

**What to do** (in GitHub repo settings, before Phase 5):
- Require pull request reviews before merge (at least 1 approval)
- Require status checks to pass before merge (the `nix flake check` CI
  from Phase 5)
- Restrict who can push to `main` (no direct pushes)
- The agent's PAT user must NOT be a repo admin or have bypass permissions
- The repo should be private (contains infrastructure details)

**Nix-native repo config**: There's no first-class Nix way to manage
GitHub repo settings. A `nix run .#configure-github` script using `gh api`
to set branch protection rules idempotently is a possible Phase 5
deliverable (~20 lines of bash in a package). Not a prereq — can be done
manually in the repo settings UI first.

### 5. Telegram bots

Two bots needed (configured when implementing, not a hard prereq for
planning):
- Prod bot: for hermes-prod's messaging + deploy notifications
- QA bot: for hermes-qa's messaging + canary (separate bot so test
  messages don't appear in the prod chat)
- Both need tokens from @BotFather and the user's Telegram user ID

### 6. Hermes-agent Nix build succeeds on hvn-hyp1

The `v2026.6.19` tag must build successfully on hvn-hyp1 (the nspawn
setup is already running, so this is confirmed). The MicroVM uses the same
hermes-agent package — if the nspawn build works, the MicroVM build will
too (same nixpkgs, same flake input).

## Design decisions

### 1. Declarative existence, imperative updates (hybrid microvm.nix)

**Decision**: Use microvm.nix's `flake = self; updateFlake` hybrid mode. The
guest hosts produce standalone `nixosConfiguration` outputs (they do NOT use
`intoAttr = [ ]`).

**Why not `intoAttr = [ ]`** (as sini does for GPU passthrough guests): sini
uses `intoAttr = [ ]` so guests don't appear as standalone deploy targets
in colmena — they're only built embedded in the host's `microvm.vms`. But we
need the guest config to be resolvable by `microvm -u`, which evaluates
`flake#nixosConfigurations.<name>` to build the VM runner. With
`intoAttr = [ ]`, no `nixosConfiguration` output exists and `microvm -u`
fails. We also need it for the agent's self-validation workflow: the agent
runs `nix eval .#nixosConfigurations.hermes-prod.config...` inside the VM
to check its own PRs before opening them.

The downside of standalone outputs is that the guests also appear as
deploy-rs nodes. This is harmless — the deploy service never runs deploy-rs,
and a human running `nix run .#deploy-rs -- .hermes-prod` would just fail
(there's no SSH endpoint to a VM). We can also filter them out of the
deploy-rs node set by setting `deployment.enable = false` in the guest
config (the deploy-rs aspect filters on
`config.deployment.enable or false`).

**Why not fully declarative**: Fully declarative VMs (`microvm.vms.<name>.config`)
require `nixos-rebuild switch` on the host for every VM change. This couples
Hermes deploys to host deploys — exactly what we want to avoid. The agent
should be able to change its own config and have it deployed without
rebuilding hvn-hyp1's kernel, Incus, ZFS, etc.

**Why not fully imperative**: Fully imperative VMs (`microvm -c`) are created
out-of-band and have no Nix config in the repo. The VM's definition wouldn't
be version-controlled, which breaks the self-modification workflow (the agent
can't PR a change to a VM that doesn't exist in git).

**The hybrid**: Declare the VM's existence and baseline config in the host's
NixOS config via `microvm.vms.<name>.flake = self`. This auto-provisions the
VM on first host deploy. Set `updateFlake = "git+file:///var/lib/hermes-deploy/homelab"`
so subsequent updates use `microvm -u <name>` against a local git checkout —
no host rebuild needed. The host only needs rebuilding when adding/removing
VMs or changing their baseline existence, not for routine config changes.

```nix
microvm.vms.hermes-prod = {
  autostart = true;
  # Flake ref for initial provisioning + the source microvm -u reads from
  flake = self;
  updateFlake = "git+file:///var/lib/hermes-deploy/homelab";
  # restartIfChanged defaults to false for flake-based VMs —
  # the deploy service controls restart timing explicitly
};
```

### 2. Hypervisor: cloud-hypervisor with bridge + NAT

**Decision**: Use cloud-hypervisor (`microvm.hypervisor = "cloud-hypervisor"`)
with a host-side bridge + NAT. The VMs are on a private subnet (10.27.50.0/24)
behind NAT, not on the physical network.

**Why cloud-hypervisor**: Rust-based (memory safety), minimal attack surface,
fast boot, native virtiofs support. For a long-running VM exposed to
untrusted input (LLM API responses, Telegram messages, web content the
agent fetches), the memory-safe VMM is a meaningful security boundary.

**Why not QEMU user networking**: QEMU's user-mode networking avoids host
config but requires QEMU as the hypervisor — a C codebase with a large
attack surface. The ~20 lines of host-side networking config for
cloud-hypervisor is a worthwhile trade for the memory-safe VMM.

**Network topology**: The VMs are NOT on the physical LAN. A host-internal
bridge (`br-microvm`, 10.27.50.1/24) connects the VMs. NAT masquerades
their traffic through `eno1`. The only inbound path to the VMs is Tailscale
(which tunnels over the NAT'd outbound connection). This is the same
security posture as QEMU user networking — outbound only, no exposed ports
— but with explicit host config instead of a built-in NAT.

**Host-side config** (~15 lines, in the microvm-host aspect):

```nix
systemd.network = {
  enable = true;
  netdevs.br-microvm.netdevConfig = {
    Kind = "bridge";
    Name = "br-microvm";
  };
  networks.br-microvm = {
    matchConfig.Name = "br-microvm";
    addresses = [{ Address = "10.27.50.1/24"; }];
  };
  # Attach microvm tap interfaces to the bridge
  networks.microvm-tap.matchConfig.Name = "vm-*";
  networks.microvm-tap.networkConfig.Bridge = "br-microvm";
};

networking.nat = {
  enable = true;
  internalInterfaces = [ "br-microvm" ];
  externalInterface = "eno1";
};
```

**VM-side config** (~8 lines, in each guest host):

```nix
systemd.network.networks."20-eth0" = {
  matchConfig.Name = "eth0";
  networkConfig = {
    Address = [ "10.27.50.20/24" ];
    Gateway = "10.27.50.1";
    DNS = [ "1.1.1.1" ];
    DHCP = "no";
  };
};
```

**Why not macvtap**: macvtap puts the VM directly on the physical network
(L2), which the user explicitly doesn't want. The bridge + NAT keeps the
VM on a private subnet.

**Firecracker** was already disqualified (no virtiofs). **crosvm** has
broken 9p. **kvmtool** has no virtiofs. cloud-hypervisor is the only
memory-safe hypervisor with virtiofs support.

**Inter-VM isolation**: hermes-prod and hermes-qa are on the same bridge
(br-microvm), so they can reach each other at L2. In practice neither VM
has services listening except SSH + Tailscale, and the hypervisor provides
kernel-level isolation between VMs. If L2 isolation is desired, a few
nftables rules on the host drop inter-VM traffic without needing separate
bridges:

```nix
# In the microvm-host aspect:
networking.nftables.rules."10-inter-vm-isolation" = ''
  chain forward {
    type filter hook forward priority 10;
    # Drop traffic between VMs on br-microvm
    iifname "vm-*" oifname "vm-*" drop
    # Allow VMs to reach the gateway (for NAT) and outside
    iifname "vm-*" oifname != "vm-*" accept
  }
'';
```

This is optional — the hypervisor boundary is the real isolation. The
nftables rules are defense-in-depth for the case where one VM is
compromised and tries to attack the other.

**Known gap (deferred)**: The VMs can currently reach the host's LAN
(172.27.50.x) since the host routes between br-microvm and eno1. The NAT
only masquerades outbound to the internet; it doesn't block lateral
movement to other homelab devices. Restricting VM outbound to only
internet + Tailscale (blocking LAN access) requires additional nftables
rules on the host. This is deferred for now — the VMs only run hermes-agent
(which makes outbound HTTPS to APIs), and the agent doesn't have tools to
scan the LAN. But it should be addressed before the agent gains network
tools (e.g., a web browser skill).

### 3. Impermanence with a tiny persist share

**Decision**: The Hermes MicroVM uses impermanence. The VM has no persistent
root disk — it boots fresh from `/nix/store` on every start. A virtiofs
share from the host mounts at `/persist`, carrying only the agent's mutable
state. Everything else (NixOS generations, git checkout, logs, caches) is
ephemeral and wiped on each boot.

**Why impermanence here**: Without it, the VM root disk accumulates NixOS
system generations (GBs), a git checkout (hundreds of MB), logs, and caches.
ZFS snapshots of the VM state dataset would be large and slow. The actual
valuable state — skills, SOUL.md, sessions, memories, cron jobs, Tailscale
identity — is probably 10-50 MB total. Impermanence lets us snapshot only
what matters.

**How it works**:

The VM has no persistent root disk. On each boot:
1. The VM boots from the microvm runner in `/nix/store` (built by
   `microvm -u`)
2. `/nix/.ro-store` is virtiofs from the host's `/nix/store` (read-only)
3. `/nix/.rw-store` is a volume for the writable nix store overlay (ephemeral,
   recreated each boot)
4. `/persist` is a virtiofs share from the host's
   `/var/lib/microvms/hermes-prod/persist/` (on ZFS, snapshotted)
5. The impermanence module bind-mounts persisted paths from `/persist` into
   their expected locations

**What persists** (in `/persist`, on the host's ZFS dataset):
- `/persist/var/lib/hermes/.hermes/` → agent state (bind-mounted to
  `/var/lib/hermes/.hermes/`):
  - `skills/` — agent-created skills
  - `SOUL.md` — agent personality
  - `sessions/` — conversation history + `resume_pending` markers
  - `memories/` — long-term memory
  - `cron/` — scheduled job definitions
- `/persist/var/lib/hermes/workspace/` → the git checkout for the agent
  to work in. Persisted so the agent's uncommitted work survives VM
  restarts. The agent should still commit + push before expecting a deploy,
  but a restart mid-edit won't lose work. The agent sees this as
  `/workspace/homelab` (the hermes module's `workingDirectory` or a
  symlink from `/workspace` → `/var/lib/hermes/workspace`).
- `/persist/var/lib/tailscale/` → bind-mounted to `/var/lib/tailscale/`
  (Tailscale node identity)

**What does NOT persist** (ephemeral, regenerated on each boot):
- `config.yaml` — Nix-generated by the hermes activation script on each
  boot. Written to `/var/lib/hermes/.hermes/config.yaml` (on the ephemeral
  root, not in `/persist`). If it were in `/persist`, a rollback would
  restore a stale config that mismatches the new system closure.
- `.env` — Nix-generated from the agenix secret share on each boot. Same
  reasoning — never persisted.
- NixOS system files (come from `/nix/store`)
- Logs, caches, temp files
- `/nix/.rw-store` (writable store overlay — build cache, not state)

**Important**: `config.yaml` and `.env` are written by the hermes NixOS
activation script on each boot to the ephemeral root. They are NOT in
`/persist`. The `persist = [ "/var/lib/hermes" ]` declaration in the
hermes aspect must be scoped to exclude these — either by persisting
specific subdirectories (`/var/lib/hermes/.hermes/skills`,
`/var/lib/hermes/.hermes/sessions`, etc.) rather than the whole
`/var/lib/hermes` tree, or by using impermanence's `files`/`directories`
with explicit paths. The implementing agent should verify that the
impermanence module doesn't bind-mount `config.yaml` or `.env` from
`/persist` (which would override the Nix-generated versions).

**Using the existing impermanence aspect**: The MicroVM should include
`den.aspects.disk.impermanence` (the same aspect the hosts use). This
aspect imports the impermanence NixOS module, declares `/persist` as
neededForBoot, and includes the persist-collector (which gathers `persist`
entries from all aspects and feeds them to `environment.persistence`).

The ZFS rollback part of the impermanence aspect (the `initrd-zfs-rollback`
service) is gated on `host.hasAspect den.aspects.disk.zfs` — it only
activates if the host has the ZFS disk aspect. The MicroVM does NOT have
ZFS (its root is ephemeral from `/nix/store`, and `/persist` is a virtiofs
share), so the ZFS rollback service won't be added. This is correct: the
VM's root is already ephemeral (boots fresh each time), so there's nothing
to roll back inside the VM.

**How ZFS rollback interacts with the VM**: ZFS snapshots and rollbacks of
the persist dataset happen on the **host side**, not inside the VM. When
the deploy service runs `zfs rollback rpool/microvms/hermes-prod/persist@pre-deploy-<ts>`
on hvn-hyp1, it rolls back the host's ZFS dataset that backs the virtiofs
share. The VM's `/persist` mount immediately reflects the rolled-back
state — the VM doesn't know or care that ZFS is involved. The VM just sees
its `/persist` directory change contents. If the VM is running during the
rollback (Layer 3 in the rollback chain), the VM is stopped first, the
ZFS rollback happens on the host, then the VM is restarted — so the VM
never sees a mid-flight `/persist` change.

The separation is clean:
- **Inside the VM**: impermanence aspect (minus ZFS rollback) bind-mounts
  from `/persist`. No ZFS awareness.
- **On the host**: ZFS manages the persist dataset. Snapshots and
  rollbacks happen at the ZFS level, transparent to the VM.

**Snapshot size**: A ZFS snapshot of
`rpool/microvms/hermes-prod/persist/` captures the agent state, the git
workspace (working tree + .git), and Tailscale identity. The git workspace
is the largest component (the .git directory can be 100-200 MB for a repo
this size), but ZFS snapshots are incremental — only changed blocks are
stored. Snapshots before each deploy are still much smaller than snapshotting
a full VM root disk with NixOS generations.

**Rollback with impermanence**: `zfs rollback` the persist dataset + restart
the VM. The VM boots fresh from the (unchanged) nix store runner, mounts the
rolled-back persist share, and the agent's state is restored to the
pre-deploy snapshot. No need to roll back the VM's system closure
separately — it's ephemeral.

### 4. Deploy trigger: webhook + polling fallback

**Decision**: A webhook receiver on hvn-hyp1 (via Tailscale Funnel)
triggers immediate deploys. A polling timer runs every 2 minutes as a
fallback to catch any webhooks that were missed.

**Why not polling only**: Polling adds 1-2 minutes of latency to every
deploy. For a personal assistant that just merged a PR to add a skill, that
feels slow. The webhook gives near-instant feedback.

**Why not webhook only**: GitHub does not retry failed webhook deliveries.
If hvn-hyp1 is rebooting, the deploy service is down, or Tailscale Funnel
has a transient failure, the webhook is lost and the deploy never happens.
The polling timer catches these gaps — it checks for any commits on main
that haven't been deployed yet and processes them.

**Polling rate limit**: The deploy service uses `git fetch origin main`,
which is git protocol over HTTPS — not the GitHub REST API. It does not
count against the 5000 req/hour API rate limit. We can poll every 1-2
minutes with no rate limit concern. The PAT is used for authentication to
the private repo, not for API calls.

**How it works**:

```
GitHub (main branch)
  │
  ├── webhook push event ──► Tailscale Funnel ──► hermes-deploy-webhook.service
  │                                                  (immediate trigger)
  │
  └── hermes-deploy.timer (every 2 min) ──► hermes-deploy.service
                                               (catch-up: deploys any
                                                undeployed commits)

hermes-deploy.service on hvn-hyp1:
  1. git fetch origin main (read-only PAT from agenix)
  2. Read last-deployed commit from /var/lib/hermes-deploy/last-deployed
  3. git diff <last-deployed>..origin/main --name-only
  4. If no changes: update last-deployed, exit
  5. Classify changes (see below) and deploy VMs if any guest config changed
  6. Alert separately if host config changed (but never block VM deploys)
  7. Update last-deployed to origin/main
```

**Aggressive VM deploys**: `microvm -u` only rebuilds the VM's guest NixOS
config from the flake — it never touches the host. So host file changes
should never block VM deploys. The deploy service always runs `microvm -u`
for any VM whose guest-side config changed, regardless of what else changed
in the same commit. Host-side changes (hvn-hyp1 config, microvm-host aspect)
trigger a separate Telegram alert asking for a manual host deploy, but do
not block the VM update.

The only case where a VM deploy is skipped is when *no* guest-side files
changed (e.g., a pure hvn-hyp1 change with no hermes-* or shared aspect
changes). In that case there's nothing for `microvm -u` to do.

Change classification:

| Files changed | VM deploy? | Host alert? |
|---|---|---|
| `modules/den/hosts/hermes-*/**` (guest-side) | Yes — SSH switch affected VMs | No |
| `modules/den/aspects/services/hermes.nix` | Yes — SSH switch both VMs | No |
| `modules/den/aspects/services/hermes-deploy.nix` | No (guest doesn't use this) | Yes — host rebuild needed |
| `modules/den/aspects/virtualization/microvm-host.nix` | No (host-side microvm config) | Yes — host rebuild needed |
| `modules/den/aspects/virtualization/microvm-guests.nix` | No (host-side guest resolution) | Yes — host rebuild needed |
| `modules/den/hosts/hvn-hyp1/**` | If `microvm.guests` list changed: Yes — SSH switch affected VMs. Otherwise: No | Yes — host rebuild needed for non-microvm hvn-hyp1 changes |
| `flake.lock` | Yes — SSH switch both VMs (input changes affect guest closures) | Yes if host inputs also changed |
| `.github/workflows/**` | No | No |
| Any combination of the above | VM deploy if any guest-side files changed | Host alert if any host-side files changed |

The VM deploy and host alert are independent — both can fire on the same
commit.

The deploy service runs as a dedicated system user with:
- Read-only access to the git repo (via PAT)
- Access to `microvm` command (member of `kvm` group)
- Access to `nix` for evaluation
- SSH key authorized on hermes-prod/qa (for `switch-to-configuration
  switch` and canary checks via bridge IPs — not Tailscale)
- No deploy-rs access, no agenix master keys

The repo checkout lives at `/var/lib/hermes-deploy/homelab` on hvn-hyp1.
This is the same path referenced by `updateFlake` in the microvm config.
The deploy service owns this checkout; the agent inside the VM does not
have direct filesystem access to it (the VM only has its own
`/workspace/homelab` checkout for editing).

### 5. GitHub Actions for checks and auto-merge only (no SSH)

**Decision**: GH Actions runs `nix flake check` and auto-merges non-infra
PRs. It never deploys.

**Auto-merge logic**: A GH Action checks the PR's changed files:
- `modules/den/aspects/services/hermes/documents/**` — auto-merge (docs the
  agent sees in its workspace — reference material, not skills)
- `modules/den/hosts/hermes-*/documents/**` — auto-merge
- Everything else under `modules/` — requires human review

The action uses `gh pr merge --squash --auto` when the PR is purely
non-infra and all checks pass. For infra PRs, it posts a comment asking for
review. The deploy service on hvn-hyp1 picks up the merge via webhook
(immediate) or polling (within 2 min).

Note: `documents/**` files are workspace reference docs (USER.md, project
context), not skills. Skills live in `~/.hermes/skills/` (VM state, not the
repo — see section 8). The auto-merge path is for non-executable context
files that the agent PRs to share with itself across deploys.

### 6. Tailscale on both VMs (with authKeyFile)

**Decision**: Both hermes-prod and hermes-qa join the tailnet using
`authKeyFile` provisioned via agenix. No interactive auth needed.

**Why**: Direct SSH access for administration without exposing ports through
The deploy service reaches the VMs via bridge IPs for canary checks (not
Tailscale — see section 10). Using `authKeyFile` means the VMs
auto-authenticate on first boot — no manual `tailscale up` step.

**Networking setup**:
- Each VM has a `tap` interface attached to the host's `br-microvm` bridge
  (private subnet 10.27.50.0/24, NAT'd through hvn-hyp1's eno1)
- The VM is NOT on the physical LAN — it's behind NAT on a private subnet
- Tailscale runs inside the VM, creating a `tailscale0` interface over
  the NAT'd outbound connectivity
- The VM is reachable on the tailnet at `hermes-prod.<tailnet>` and
  `hermes-qa.<tailnet>`
- `services.tailscale.authKeyFile` points to an agenix-provisioned auth key
  (separate key per VM — see Open Questions)

**Tailscale state persistence**: `/var/lib/tailscale` is persisted via
`/persist` (bind-mounted from the virtiofs share) so the node identity
survives VM restarts. After the first boot authenticates via `authKeyFile`,
subsequent boots reuse the persisted identity and don't need the auth key.

### 7. Does the agent need access to other Git repos?

**Short answer**: No, not as infrastructure. The agent can clone and work
on any repo as a workspace, but only homelab is "infra-wired" (changes
trigger deploys).

**Long answer**: A personal assistant might want to work on the user's other
projects — dotfiles, open-source contributions, work repos. These are
workspaces, not infrastructure. The agent clones them into
`/workspace/<repo>` inside the VM, works on them, and pushes PRs. But none of
them trigger Nix deploys or VM rebuilds.

If the user's homelab grows to include multiple infrastructure repos (e.g.,
a separate DNS repo, a separate monitoring repo), each would get its own
deploy service instance. The agent would have PATs for each, and each would
have its own QA/prod pipeline. But that's future scope — for now, one repo.

The agent's GitHub PAT is scoped to `repo:write` on homelab only. If the
user wants the agent to work on other repos, they add separate PATs (also
agenix-provisioned) with scoped access. But those repos are never deployed
by the homelab pipeline.

### 8. Skills and SOUL.md: VM state only

**Decision**: All agent state — skills, SOUL.md, memories, cron jobs —
lives in the VM's persisted state (`/var/lib/hermes/.hermes/`). The agent
has full autonomy to create, modify, and delete these at runtime. Nothing
is deployed declaratively from the repo.

**Why not deploy skills from the repo**: Deploying skills via Nix's
`documents` option installs files into the workspace on every rebuild. But
the agent creates skills at runtime in `~/.hermes/skills/` — that's where
Hermes looks for them. Having two sources of skills (Nix-deployed workspace
files + runtime-created `~/.hermes/skills/`) creates confusion about which
skills are active and who owns them. One source of truth is simpler.

**Why not version-control SOUL.md**: SOUL.md is the agent's personality. It
evolves through conversation and self-reflection. Putting it in the repo
means every personality change is a git commit — noisy, and it couples the
agent's identity to the deploy cycle. The agent should be free to rewrite
its own personality without opening a PR.

**What the repo controls instead**: The repo controls the agent's
*infrastructure* — model, packages, service config, messaging config. The
agent controls its *behavior* — skills, personality, memory. This is the
right split: infrastructure changes need review, behavior changes don't.

**If the user wants visibility into the agent's skills**: They can SSH to
the VM via Tailscale and browse `~/.hermes/skills/`. Or the agent can be
asked (via Telegram) to list its skills, and it can self-report. If
version-controlling specific skills becomes desirable later, the agent can
PR them to the repo as workspace documents — but this is opt-in, not the
default.

### 9. Graceful deploy: drain before restart

**Decision**: Configure `agent.restart_drain_timeout` in the hermes settings
so the gateway drains active conversations before the VM shuts down. The
deploy service uses `microvm -u` (update without restart) followed by a
graceful restart that gives the gateway time to drain.

**Why this matters**: The agent could be mid-conversation or mid-tool-call
when a deploy triggers a VM restart. Without a drain, the work is lost. With
a drain, the gateway:

1. Stops accepting new turns
2. Marks active sessions as `resume_pending`
3. Waits up to `restart_drain_timeout` for in-flight agents to finish
4. Writes a `.clean_shutdown` marker
5. Exits gracefully

On the next boot, the gateway sees `resume_pending` sessions and resumes
them — the agent picks up where it left off.

**Configuration**:

```nix
services.hermes.agent = {
  model.default = "opencode-go/mimo-v2.5-pro";
  # This is a hermes config.yaml key, rendered via settings:
  settings.agent.restart_drain_timeout = 120;  # 2 min
};
```

The systemd unit's `TimeoutStopSec` must exceed the drain timeout (120s).
The hermes NixOS module sets `KillMode=mixed` and `KillSignal=SIGTERM`. When
the VM shuts down, systemd inside the VM sends `SIGTERM` to hermes-agent,
which triggers the drain. If the drain doesn't complete within
`TimeoutStopSec`, systemd sends `SIGKILL` — so `TimeoutStopSec` should be
set to `restart_drain_timeout + 30` (150s) as a safety margin.

**Deploy sequence**: The deploy service does NOT use `microvm -Ru` (which
restarts immediately). Instead it:
1. `microvm -u hermes-prod` — build and update the `current` symlink without
   restarting the running VM
2. `systemctl restart microvm@hermes-prod` — restart the VM service, which
   shuts down the old VM (triggering the drain inside) and boots the new one

The restart sends `SIGTERM` to the VM process. Inside the VM, systemd
receives the shutdown signal and sends `SIGTERM` to hermes-agent, which
drains. The VM stays alive until the drain completes or `TimeoutStopSec`
fires (whichever comes first), then the new VM boots from the updated
`current` symlink.

**Note**: The graceful drain (`SIGUSR1`) is used by hermes' own self-restart
mechanism (`hermes gateway restart`), not by VM-level restarts. For VM
restarts, the drain is triggered by `SIGTERM` + the `restart_drain_timeout`
config. This is the correct mechanism for our use case — we're restarting the
whole VM, not just the gateway process.

**Workspace persistence**: The git workspace (`/var/lib/hermes/workspace`)
is persisted in `/persist` alongside the agent state. This means the agent's
uncommitted git work survives a VM restart — important because the agent
could be mid-PR when a deploy triggers. The workspace is part of the ZFS
snapshot, so a rollback also restores the workspace state.

### 10. Deployment mechanism: SSH-based switch with microvm -u fallback

**Decision**: Routine config changes deploy via SSH-based
`switch-to-configuration switch` inside the running VM. `microvm -u` + full
VM restart is the fallback for unreachable VMs and microvm-level changes.

**Why SSH-based, not `microvm -u`**: `microvm -u` + `systemctl restart
microvm@hermes-prod` restarts the entire VM — kernel, init, all services.
That's 10-30 seconds of full downtime plus boot sequence. An SSH-based
`switch-to-configuration switch` only restarts *changed services*. If the
agent's config changed, only `hermes-agent` restarts (with graceful drain).
The VM stays up, sessions resume, downtime is seconds not minutes.

**Why no deploy-rs/colmena**: The VM shares the host's `/nix/store` via
virtiofs. The deploy service builds on the host (fast, has CPU/RAM), and the
result is instantly visible inside the VM at the same store paths. No
`nix-copy-closure` needed. The deploy is:

```bash
# Build on host (result lands in shared /nix/store)
nix build .#nixosConfigurations.hermes-prod.config.system.build.toplevel

# SSH into VM via bridge IP, activate the new closure (only restarts changed services)
ssh 10.27.50.20 "$(readlink result)/bin/switch-to-configuration switch"
```

No deploy-rs, no colmena, no in-VM nix build. ~3 lines of bash. The host
builds, the shared store delivers, SSH activates.

**Why bridge IP, not Tailscale**: The deploy service runs on hvn-hyp1 — the
same host running the VMs. It can reach the VMs directly via the br-microvm
bridge IPs (10.27.50.20/21). Going through Tailscale would add an
unnecessary dependency: if Tailscale is down, deploys would fail even
though the VM is reachable on the bridge. Tailscale is for the user's admin
SSH access; the deploy service uses the direct bridge path.

The canary checks also use bridge IPs. Tailscale is not a deploy-time
dependency at all — it's only needed for: (a) the user's admin SSH, (b)
Tailscale Funnel for the webhook endpoint. If Tailscale is completely down,
deploys still work (polling catches the commit, build + SSH switch + canary
all go over the bridge).

**Fallback to `microvm -u`**: if SSH fails (VM crashed, hung, bridge
unreachable, OOM), the deploy service catches the failure and falls back:

```bash
microvm -u hermes-prod          # rebuild runner from local flake checkout
systemctl restart microvm@hermes-prod  # full VM restart
```

This works when the VM is unresponsive — it's a host-side operation that
doesn't require the VM to be up. Full VM restart, but reliable recovery.

**When `microvm -u` is required (not just fallback)**:
- First provisioning (VM doesn't exist yet)
- Microvm-level changes (vcpu, mem, interfaces, shares) — these need a VM
  restart, not a service restart. SSH switch can't change VM resources.
- Hermes-agent package bump (the pinned rev changes) — the new package is
  in a different store path; SSH switch handles this, but if the package
  is large and the VM's writable overlay fills up, `microvm -u` from the
  host avoids the overlay entirely

**What the `microvm` CLI provides** (that we build on):
- `microvm -u <name>` — rebuild a VM from its flake ref (the local git
  checkout via `updateFlake`)
- `microvm -l` — list VMs with status (active/outdated/stale)
- `current` / `booted` / `old` symlinks in the state dir for rollback

**What we add** (the homegrown parts):
- Webhook receiver + polling timer for change detection
- Path-based classification (guest vs host changes)
- Host-side nix build + SSH switch-to-configuration for routine deploys
- Fallback to `microvm -u` + full restart when SSH is unreachable
- QA→prod gate with end-to-end canary
- ZFS snapshot before prod deploy
- Automatic post-deploy rollback chain
- Telegram notifications (direct Bot API, see section 12)
- Deploy result file for agent self-awareness (see Deploy result notification)

These are straightforward bash scripts wrapped in a NixOS systemd service.
The complexity is in the orchestration logic, not in the VM management —
microvm.nix handles the actual VM lifecycle.

### 11. Agent bootstrap — idempotent oneshot services

**Decision**: Three idempotent oneshot systemd services handle the parts
the NixOS hermes module doesn't: git workspace clone, `gh` authentication,
and git identity. Each runs on every boot but only acts if the state is
missing (clone if no repo, auth if not authenticated, config if not set).

**What the NixOS hermes module already handles**: The module creates the
`hermes` user, generates `config.yaml` from `settings`, wires up
`environmentFiles` (agenix secrets → `.env`), and starts the gateway
service. CLI commands like `hermes setup` / `hermes config set` are
**blocked** in NixOS-managed mode to prevent drift. So the agent's config
is fully Nix-driven — no interactive setup needed.

**What the module does NOT handle**: The git workspace (the repo clone for
the agent to work in), `gh` CLI authentication (the PAT is in agenix but
`gh` doesn't know to use it), and git identity (user.name / user.email for
commits).

**The three oneshot services** (in the hermes aspect, VM side):

```nix
# 1. Clone workspace if missing
systemd.services.hermes-workspace-clone = {
  description = "Clone homelab workspace for agent";
  after = [ "hermes-agent.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig.Type = "oneshot";
  serviceConfig.RemainAfterExit = true;
  script = ''
    workspace="/var/lib/hermes/workspace/homelab"
    if [ ! -d "$workspace/.git" ]; then
      pat=$(cat /run/agenix/hermes-github-pat)
      git clone "https://x-access-token:$pat@github.com/dvicory/homelab.git" "$workspace"
    fi
    # Always fetch latest so the agent starts with current main
    cd "$workspace"
    git fetch origin
  '';
};

# 2. Authenticate gh CLI
systemd.services.hermes-gh-auth = {
  description = "Authenticate gh CLI with PAT";
  after = [ "hermes-agent.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig.Type = "oneshot";
  serviceConfig.RemainAfterExit = true;
  script = ''
    pat=$(cat /run/agenix/hermes-github-pat)
    echo "$pat" | gh auth login --with-token
  '';
};

# 3. Set git identity
systemd.services.hermes-git-config = {
  description = "Set git identity for agent commits";
  after = [ "hermes-agent.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig.Type = "oneshot";
  serviceConfig.RemainAfterExit = true;
  script = ''
    git config --global user.name "Hermes Agent"
    git config --global user.email "hermes@localhost"
  '';
};
```

All three are idempotent: `git clone` fails harmlessly if the dir exists
(guarded by `[ -d .git ]`), `gh auth login --with-token` re-authenticates
on every boot (cheap, ensures the PAT is current), `git config` overwrites
the same values. The `git fetch` on every boot ensures the agent starts
with the latest `origin/main` — but does NOT reset or pull, so the agent's
local branches and uncommitted work are preserved.

**Bootstrap order**: hermes-agent starts first (the module handles this),
then the three oneshot services run. The agent's SOUL.md / startup skill
should instruct it to wait for the workspace to be ready before attempting
git operations. Alternatively, the oneshots can run `before` hermes-agent
if the agent needs the workspace at startup — but the agent likely doesn't
need git access immediately on boot, and running the oneshots after avoids
delaying gateway startup.

### 12. Deploy notifications — direct Telegram Bot API

**Decision**: The deploy service sends Telegram notifications directly via
the Telegram Bot API (curl), reusing the prod bot's token. No dependency
on the hermes gateway being up.

**Why not through hermes**: If the deploy failed because hermes crashed, the
gateway can't send a notification. The deploy service must have its own
notification path that works regardless of agent state.

**Why reuse the prod bot token**: Same chat as agent messages — the user
sees deploy notifications and agent responses in one place. No separate bot
to manage. The deploy service gets the bot token + chat ID via agenix (it
runs on the host, which has agenix access).

**How it works**: The deploy service reads `TELEGRAM_BOT_TOKEN` and
`TELEGRAM_CHAT_ID` from the prod hermes-env secret (or a dedicated
deploy-notification secret). Notifications are sent via:

```bash
curl -s "https://api.telegram.org/bot$TOKEN/sendMessage" \
  -d "chat_id=$CHAT_ID" \
  -d "text=Deploy to hermes-prod: $STATUS. $DETAILS"
```

This is a direct HTTPS call to Telegram's API — no hermes dependency, works
when the agent is down, works when the VM is being restarted. The deploy
service runs on the host (hvn-hyp1) which has outbound internet.

**Notification triggers**:
- Deploy started (QA): "Deploying PR '<subject>' to hermes-qa..."
- QA canary passed: "QA canary passed. Deploying to hermes-prod..."
- Deploy succeeded: "Deployed '<subject>' to hermes-prod. <action_taken>"
- QA canary failed: "QA canary FAILED. Prod NOT deployed. <canary_output>. Rolling back QA..."
- Rollback completed: "Rolled back hermes-prod (Layer <N>). <action_taken>"
- All rollback layers exhausted: "CRITICAL: hermes-prod rollback failed. Manual intervention needed."
- Host changes detected: "Host config changed in <commit>. Manual host deploy required: nix run .#deploy-rs -- .hvn-hyp1"

**Matrix**: The user wants Matrix for hermes messaging. The deploy service
could also send to a Matrix room via the client-server API, but that adds
Matrix as a deploy-service dependency. Recommend starting with Telegram
only for deploy notifications (simplest, the user already has Telegram set
up), and adding Matrix notifications later if desired. The notification
mechanism is a function call — adding a second channel is a few lines of
curl.

**Decision**: Routine config changes deploy via SSH-based
`switch-to-configuration switch` inside the running VM. `microvm -u` + full
VM restart is the fallback for unreachable VMs and microvm-level changes.

**Why SSH-based, not `microvm -u`**: `microvm -u` + `systemctl restart
microvm@hermes-prod` restarts the entire VM — kernel, init, all services.
That's 10-30 seconds of full downtime plus boot sequence. An SSH-based
`switch-to-configuration switch` only restarts *changed services*. If the
agent's config changed, only `hermes-agent` restarts (with graceful drain).
The VM stays up, sessions resume, downtime is seconds not minutes.

**Why no deploy-rs/colmena**: The VM shares the host's `/nix/store` via
virtiofs. The deploy service builds on the host (fast, has CPU/RAM), and the
result is instantly visible inside the VM at the same store paths. No
`nix-copy-closure` needed. The deploy is:

```bash
# Build on host (result lands in shared /nix/store)
nix build .#nixosConfigurations.hermes-prod.config.system.build.toplevel

# SSH into VM via bridge IP, activate the new closure (only restarts changed services)
ssh 10.27.50.20 "$(readlink result)/bin/switch-to-configuration switch"
```

No deploy-rs, no colmena, no in-VM nix build. ~3 lines of bash. The host
builds, the shared store delivers, SSH activates.

**Fallback to `microvm -u`**: if SSH fails (VM crashed, hung, bridge
unreachable, OOM), the deploy service catches the failure and falls back:

```bash
microvm -u hermes-prod          # rebuild runner from local flake checkout
systemctl restart microvm@hermes-prod  # full VM restart
```

This works when the VM is unresponsive — it's a host-side operation that
doesn't require the VM to be up. Full VM restart, but reliable recovery.

**When `microvm -u` is required (not just fallback)**:
- First provisioning (VM doesn't exist yet)
- Microvm-level changes (vcpu, mem, interfaces, shares) — these need a VM
  restart, not a service restart. SSH switch can't change VM resources.
- Hermes-agent package bump (the pinned rev changes) — the new package is
  in a different store path; SSH switch handles this, but if the package
  is large and the VM's writable overlay fills up, `microvm -u` from the
  host avoids the overlay entirely

**What the `microvm` CLI provides** (that we build on):
- `microvm -u <name>` — rebuild a VM from its flake ref (the local git
  checkout via `updateFlake`)
- `microvm -l` — list VMs with status (active/outdated/stale)
- `current` / `booted` / `old` symlinks in the state dir for rollback

**What we add** (the homegrown parts):
- Webhook receiver + polling timer for change detection
- Path-based classification (guest vs host changes)
- Host-side nix build + SSH switch-to-configuration for routine deploys
- Fallback to `microvm -u` + full restart when SSH is unreachable
- QA→prod gate with end-to-end canary
- ZFS snapshot before prod deploy
- Automatic post-deploy rollback chain
- Telegram notifications

These are straightforward bash scripts wrapped in a NixOS systemd service.
The complexity is in the orchestration logic, not in the VM management —
microvm.nix handles the actual VM lifecycle.

## Architecture

### Network diagram

```
Internet
  │
  ▼
hvn-hyp1 (172.27.50.17, existing den host)
├── eno1 (physical NIC)
├── Tailscale (existing, with Funnel for webhook endpoint)
├── Incus (existing)
├── ZFS rpool (existing)
│   ├── rpool/microvms/hermes-prod/persist/  (ZFS dataset, tiny, snapshotted)
│   │   └── (agent state: .hermes/, tailscale/)
│   └── rpool/microvms/hermes-qa/persist/    (ZFS dataset, tiny, snapshotted)
│       └── (agent state: .hermes/, tailscale/)
├── /var/lib/hermes-deploy/homelab/         (git checkout for fallback microvm -u)
├── hermes-deploy-webhook.service           (receives GitHub webhooks via Funnel)
├── hermes-deploy.timer                     (polling fallback, every 2 min)
├── /run/agenix-vm/hermes-prod/             (per-VM symlink farm, 3 secrets only)
├── /run/agenix-vm/hermes-qa/               (per-VM symlink farm, 3 secrets only)
├── br-microvm (host-internal bridge, 10.27.50.1/24)
├── NAT: br-microvm → eno1                  (outbound for VMs)
├── tap: vm-hermes-prod → br-microvm (10.27.50.20/24)
└── tap: vm-hermes-qa → br-microvm   (10.27.50.21/24)

hermes-prod MicroVM (Tailscale: hermes-prod.<tailnet>)
├── cloud-hypervisor, 4 vCPU, 8 GB RAM
├── No persistent root disk — boots fresh from /nix/store each start
├── /nix/.ro-store (virtiofs ro from host /nix/store)
├── /nix/.rw-store (volume, 4 GB, ephemeral, for nix build inside VM)
├── /nix/store (overlay: ro-store + rw-store)
├── /persist (virtiofs from host rpool/microvms/hermes-prod/persist/)
│   ├── var/lib/hermes/.hermes/  (agent state — bind-mounted to /var/lib/hermes/.hermes/)
│   │   ├── skills/              (agent-created, persisted)
│   │   ├── SOUL.md              (agent-controlled, persisted)
│   │   ├── sessions/            (persisted, resume_pending on restart)
│   │   ├── memories/            (persisted)
│   │   ├── cron/                (persisted)
│   │   └── deploy-results/      (persisted — deploy result notifications)
│   │       └── latest.json      (written by deploy service after each deploy)
│   ├── var/lib/hermes/workspace/ (persisted — git checkout survives restart)
│   │   └── homelab/             (agent edits here, work not lost on deploy)
│   └── var/lib/tailscale/       (node identity — bind-mounted to /var/lib/tailscale/)
├── /var/lib/hermes/.hermes/config.yaml  (ephemeral — Nix-generated on each boot)
├── /var/lib/hermes/.hermes/.env         (ephemeral — Nix-generated from agenix on each boot)
├── Hermes agent (native systemd service, Nix-sealed venv)
│   ├── model: opencode-go/mimo-v2.5-pro
│   ├── messaging: telegram + matrix (prod bot)
│   ├── agent.restart_drain_timeout: 120  (graceful drain before restart)
│   ├── extraPackages: git, gh, nix, jq
│   └── environmentFiles: /run/agenix/hermes-env
├── Tailscale (tailscale0, authKeyFile, persisted identity via /persist)
├── Secrets: hermes-env.age, hermes-github-pat.age, tailscale-auth-key.age
├── Impermanence: only /persist survives reboots
└── Network: tap (private subnet, NAT outbound) + tailscale0 (tailnet inbound)

hermes-qa MicroVM (Tailscale: hermes-qa.<tailnet>)
├── Same structure as prod
├── 2 vCPU, 4 GB RAM (smaller — cheaper to run)
├── Different Telegram bot (qa bot)
├── Different model (can use a cheaper model for testing)
├── /workspace/homelab/ (persisted, agent works on main branch — QA tests
│   the same config as prod, just deployed to the QA VM first)
└── State isolated from prod (separate persist dataset)
```

### Writable nix store inside the VM

The agent needs to run `nix eval` and `nix flake check` inside the VM to
validate its own PRs before opening them. This requires a writable nix
store overlay:

```nix
microvm = {
  hypervisor = "cloud-hypervisor";
  interfaces = [{
    type = "tap";
    id = "vm-hermes-prod";
    mac = "02:00:00:27:50:20";
  }];
  shares = [
    {
      tag = "ro-store";
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      proto = "virtiofs";
    }
    {
      tag = "persist";
      source = "/var/lib/microvms/hermes-prod/persist";
      mountPoint = "/persist";
      proto = "virtiofs";
      readOnly = false;
    }
    {
      tag = "secrets";
      source = "/run/agenix-vm/hermes-prod";
      mountPoint = "/run/agenix";
      proto = "virtiofs";
      readOnly = true;
    }
  ];
  writableStoreOverlay = "/nix/.rw-store";
  volumes = [{
    image = "nix-store-overlay.img";
    mountPoint = "/nix/.rw-store";
    size = 4096;  # MiB — enough for eval + flake check
    autoCreate = true;
  }];
  registerClosure = true;  # populate guest nix DB from closure
};

# VM-side network config (static IP on the private subnet)
systemd.network.networks."20-eth0" = {
  matchConfig.Name = "eth0";
  networkConfig = {
    Address = [ "10.27.50.20/24" ];
    Gateway = "10.27.50.1";
    DNS = [ "1.1.1.1" ];
    DHCP = "no";
  };
};
```

The store overlay and persist share serve different purposes:
- `/nix/.rw-store` (volume) — ephemeral writable nix store overlay, for
  running `nix eval` / `nix build` inside the VM. Not persisted. Reset on
  each VM restart.
- `/persist` (virtiofs from host ZFS) — persistent agent state, for
  impermanence bind-mounts. Snapshotted before each deploy. Tiny.

`registerClosure` re-populates the nix DB on each boot so the guest knows
about the host store paths.

### Secrets flow — agenix in the guest, identity via virtiofs

**Decision**: Guests have agenix. The guest's agenix identity (private key)
is delivered via virtiofs from the parent host. All other guest secrets are
encrypted to the guest's own public key and decrypted inside the guest.

**Why agenix in the guest (not just virtiofs delivery)**:
- **Portability**: if the guest ever moves to a different hypervisor, only
  the `agenix-identity.age` (one bootstrap secret) needs re-encryption to
  the new parent's key. All other secrets are already encrypted to the
  guest's key and travel unchanged.
- **Consistency**: the guest uses the same agenix workflow as any other
  host — `secretRequests`, `age.secrets`, rekeyed files in the nix store.
  No special "pre-decrypted secrets" mode.
- **Self-modification**: the agent manages its own secrets in its own
  namespace (`.secrets/guests/<name>/`) using the same agenix commands it
  would use on any host.

**File layout**:

```
.secrets/
├── hosts/
│   └── hvn-hyp1/
│       ├── gocryptfs-media1.age          # host secrets, rekeyed to host key
│       ├── hermes-env.age                # nspawn hermes (current)
│       └── rekeyed/                      # rekeyed for hvn-hyp1
├── guests/
│   └── hermes-qa/
│       ├── runtime_host_key.pub          # plaintext, agenix-rekey reads this
│       ├── agenix-identity.age           # encrypted to PARENT's key (bootstrap)
│       ├── hermes-env.age                # encrypted to GUEST's key (master-encrypted)
│       ├── hermes-github-pat.age         # encrypted to GUEST's key
│       ├── ssh-host-key.age              # encrypted to GUEST's key
│       └── rekeyed/                      # auto-generated by agenix rekey
│           ├── <hash>-hermes-env.age     # rekeyed to guest's pubkey
│           ├── <hash>-hermes-github-pat.age
│           └── <hash>-ssh-host-key.age
└── shared/
    └── tailscale-auth-key.age
```

**How it works**:

1. **`agenix rekey`** on the workstation rekeys all secrets:
   - Host secrets → host's pubkey (existing behavior)
   - Guest secrets → guest's pubkey (new — agenix-rekey discovers guests
     via the fleet policy which instantiates them)
   - `agenix-identity.age` → parent's pubkey (it's in the parent's
     `secretRequests`, not the guest's)

2. **Rekeyed files end up in the nix store** via `inputs.self` path
   evaluation. The guest accesses them through the ro-store virtiofs share
   (same as any nix store path). No separate virtiofs share needed for
   rekeyed secrets.

3. **At boot**, the parent host's agenix decrypts `agenix-identity.age`
   to `/run/agenix/hermes-qa-agenix-identity`. The per-VM symlink farm
   links it to `/run/agenix-vm/hermes-qa/agenix-identity`. The virtiofs
   "secrets" share delivers it to the guest at `/run/agenix/agenix-identity`.

4. **The guest's agenix** uses `/run/agenix/agenix-identity` as its
   `identityPaths` to decrypt its own secrets (hermes-env,
   hermes-github-pat, ssh-host-key) from the rekeyed files in the nix
   store.

5. **The guest's openssh** uses the decrypted ssh-host-key for its host
   key — stable across reboots despite impermanence (the key comes from
   agenix, not the ephemeral root).

**Schema changes**:
- `microvm.isGuest` (bool, default false) — marks a host as a MicroVM guest
- `secretPath` overrides to `.secrets/guests/<name>/` for guests (instead
  of `.secrets/hosts/<name>/`)
- Fleet policy instantiates guests even with `intoAttr = []`, overriding
  `intoAttr` to `["nixosConfigurations" <name>]`
- Agenix battery: for guests, `identityPaths = [ "/run/agenix/agenix-identity" ]`
  (from virtiofs) instead of `/persist/etc/ssh/ssh_host_ed25519_key`

**The `agenix-identity.age` bootstrap secret**:
- Encrypted to the parent's key (the parent decrypts it)
- Declared in the parent's `secretRequests` by the microvm-host aspect
  (auto-generated per guest: `secretRequests."hermes-qa-agenix-identity"`)
- Lives at `.secrets/guests/hermes-qa/agenix-identity.age` (in the guest's
  directory, but encrypted to the parent's key)
- The only secret that crosses the parent→guest trust boundary

**SSH host key for the guest**:
- The agenix identity keypair IS the SSH host key — one keypair, one
  secret, one virtiofs delivery. This mirrors how real hosts work
  (identityPaths = SSH host key, public_key = runtime_host_key.pub).
- `services.openssh.hostKeys = [{ path = "/run/agenix/agenix-identity"; type = "ed25519"; }]`
- The deploy service verifies against `agenix-identity.pub` (the same
  file agenix-rekey reads for rekeying)
- Migrating a guest to a standalone host: move files from
  `.secrets/guests/<name>/` to `.secrets/hosts/<name>/`, rename
  `agenix-identity.pub` to `runtime_host_key.pub`, set
  `microvm.isGuest = false`. Same keypair, no re-encryption.

**Trust model**:
- The parent host is the secret authority for the `agenix-identity` bootstrap
- The guest is the secret authority for its own secrets (hermes-env, PAT,
  SSH key) — they're encrypted to the guest's key
- A compromised guest can only decrypt its own declared secrets (same as
  any host with agenix)
- Moving the guest to a new parent: re-encrypt only `agenix-identity.age`
  to the new parent's key; all other secrets travel unchanged

**Secrets are NOT in `/persist`** — they're in the nix store (rekeyed
files) and `/run/agenix/` (decrypted at boot). This keeps the persist
dataset free of secret material.

### How the agent self-modifies

```
1. Agent decides it needs jq for a skill
2. Agent works in /workspace/homelab/ (inside hermes-prod VM)
   (persisted in /persist — uncommitted work survives VM restarts)
3. Agent creates branch: git checkout -b add-jq
4. Agent edits modules/den/hosts/hermes-prod/default.nix:
     services.hermes.extraPackages = [ pkgs.jq ];
5. Agent validates: nix eval .#nixosConfigurations.hermes-prod.config.environment.systemPackages
6. Agent commits, pushes, opens PR: gh pr create --title "Add jq to hermes-prod"
7. Agent reports on Telegram: "I opened PR #42 to add jq. This is an infra
   change, so it needs your review."

8. GitHub Actions runs nix flake check on the PR
9. GitHub Actions sees modules/ changed → does NOT auto-merge → asks for review
10. Human reviews, merges

11. GitHub webhook fires → hermes-deploy-webhook triggers hermes-deploy.service
    (or polling timer catches it within 2 min)
12. hermes-deploy.service on hvn-hyp1:
    a. git fetch origin main
    b. Detects hermes-prod guest config changed
    c. git reset --hard origin/main
    d. nix flake check
    e. zfs snapshot rpool/microvms/hermes-qa/persist@pre-deploy-<timestamp>
    f. Deploy to QA:
       - nix build .#nixosConfigurations.hermes-qa.config.system.build.toplevel
         (builds on host; result lands in shared /nix/store, visible to VM
          via the ro-store virtiofs share + writable overlay)
       - ssh 10.27.50.21 "$(readlink result)/bin/switch-to-configuration switch"
         (activates inside the running VM — only changed services restart)
    g. Canary: wait for hermes-qa to settle, SSH in, run:
       - systemctl is-active hermes-agent
       - timeout 30 hermes -z "Reply with exactly: CANARY_OK"
       - journalctl -u hermes-agent --since "2 min ago" -p err
    h. If canary passes:
       - zfs snapshot rpool/microvms/hermes-prod/persist@pre-deploy-<timestamp>
       - Deploy to prod (same build + SSH switch pattern as QA)
         (Only hermes-agent restarts — with graceful drain. Sessions marked
          resume_pending recover on next service start.)
       - Send Telegram: "Deployed PR #42 to hermes-prod. jq is now available."
    i. If canary fails:
       - Automatic rollback (see Rollback section below)
       - Send Telegram: "QA canary failed, prod NOT deployed. <error details>"
```

For a non-infra change (e.g., the agent PRs a reference doc):

```
1. Agent creates modules/den/aspects/services/hermes/documents/USER.md
   (context about the user — not a skill, just workspace reference)
2. Agent opens PR
3. GitHub Actions sees only documents/** changed → auto-merges
4. hermes-deploy.service picks up the merge (webhook or polling)
5. VM's hermes-agent restarts with the new doc in its workspace
6. Agent reports: "PR #43 auto-merged. USER.md updated in workspace."
```

For a non-infra change (e.g., the agent PRs a reference doc):

```
1. Agent creates modules/den/aspects/services/hermes/documents/USER.md
   (context about the user — not a skill, just workspace reference)
2. Agent opens PR
3. GitHub Actions sees only documents/** changed → auto-merges
4. hermes-deploy.service picks up the merge (webhook or polling)
5. VM restarts with the new doc in its workspace
6. Agent reports: "PR #43 auto-merged. USER.md updated in workspace."
```

### Rollback — automated post-deploy chain

When the canary fails after a prod deploy, the deploy service automatically
escalates through rollback layers from cheapest to most expensive. There is
no "diagnose the problem first" step — the chain tries each layer and
re-runs the canary after each. Whichever layer fixes it, that's the answer.

After rollback completes, the deploy service writes a deploy result file to
the VM's persist share so the agent knows what happened (see "Deploy result
notification" below).

**The chain:**

```
prod canary failed after deploy:

  if ssh_reachable(10.27.50.20):
    # Layer 1: NixOS generation rollback — cheap, no state loss, ~5s
    ssh 10.27.50.20 "nixos-rebuild switch --rollback"
    wait 15s; re-run canary
    if canary_passes: rollback_done(layer=1); break

    # Layer 3: ZFS snapshot rollback — expensive, loses agent state since snapshot
    zfs rollback rpool/microvms/hermes-prod/persist@pre-deploy-<latest>
    ssh 10.27.50.20 "nixos-rebuild switch --rollback"
    wait 30s; re-run canary
    if canary_passes: rollback_done(layer=3); break
    else: alert_human "All rollback layers exhausted. Manual intervention needed."

  else:  # VM unreachable via SSH
    # Layer 2: microvm runner rollback — VM restart, no state loss
    cd /var/lib/microvms/hermes-prod
    ln -sfn $(readlink booted) current
    systemctl restart microvm@hermes-prod
    wait 60s; check ssh_reachable 10.27.50.20; re-run canary
    if canary_passes: rollback_done(layer=2); break

    # Layer 3: ZFS snapshot rollback — same, with state restore
    zfs rollback rpool/microvms/hermes-prod/persist@pre-deploy-<latest>
    systemctl restart microvm@hermes-prod
    wait 60s; re-run canary
    if canary_passes: rollback_done(layer=3); break
    else: alert_human "All rollback layers exhausted. Manual intervention needed."

  # After rollback (success or failure), write deploy result to persist:
  write_deploy_result(
    commit=<failed-commit-hash>,
    commit_subject=<first-line-of-commit-message>,
    status="failed",
    canary_output=<canary stderr/stdout>,
    rollback_layer=<layer-that-worked>,
  )
```

**The three layers:**

| Layer | What it restores | State loss? | Downtime | When it's tried |
|---|---|---|---|---|
| 1: NixOS generation rollback | Previous system config (only changed services restart) | None | ~5s (service restart only) | First, if SSH reachable |
| 2: microvm runner rollback | Previous VM system closure (full VM restart) | None | ~30s (full boot) | First, if SSH unreachable |
| 3: ZFS snapshot rollback | Previous system config AND agent state | Agent state since snapshot | ~30-60s | Last resort, after 1 or 2 fails |

**Why escalation, not diagnosis**: "Did the agent's state cause the problem?"
is not answerable programmatically. But you don't need to answer it — Layer
1 (generation rollback) only affects system config. If that fixes it, the
problem was config. If it doesn't, try Layer 3 (state rollback). If THAT
fixes it, the problem was state. The chain resolves the diagnosis by
trying both.

### Deploy result notification

After every deploy (success or failure), the deploy service writes a JSON
result file to the VM's persist share:

```
/persist/var/lib/hermes/.hermes/deploy-results/latest.json
```

**On success:**

```json
{
  "timestamp": "2026-07-04T15:30:00Z",
  "commit": "abc123def",
  "commit_subject": "Add jq to hermes-prod",
  "status": "success",
  "deployed_to": "hermes-prod",
  "canary_output": "CANARY_OK",
  "rollback_layer": null,
  "action_taken": "Deployed via SSH switch-to-configuration. Only hermes-agent restarted (graceful drain, sessions resumed).",
  "next_step": null
}
```

**On failure (config problem, Layer 1 rollback):**

```json
{
  "timestamp": "2026-07-04T15:31:00Z",
  "commit": "abc123def",
  "commit_subject": "Add jq to hermes-prod",
  "status": "failed",
  "deployed_to": "hermes-prod",
  "canary_output": "Error: model 'foo' not found in provider catalog\n\ntimeout: the `hermes -z` command timed out after 30 seconds",
  "rollback_layer": 1,
  "action_taken": "Rolled back to previous NixOS generation via `nixos-rebuild switch --rollback` inside the running VM. Only hermes-agent restarted. Agent state (skills, SOUL.md, sessions, memories, workspace) was NOT touched — fully preserved.",
  "next_step": "Fix the invalid model name in modules/den/hosts/hermes-prod/default.nix and push a new commit."
}
```

**On failure (state problem, Layer 3 rollback):**

```json
{
  "timestamp": "2026-07-04T15:32:00Z",
  "commit": "abc123def",
  "commit_subject": "Add jq to hermes-prod",
  "status": "failed",
  "deployed_to": "hermes-prod",
  "canary_output": "Process active but no response to CANARY_OK prompt. Errors in log: KeyError in session parser.",
  "rollback_layer": 3,
  "action_taken": "Rolled back agent state via `zfs rollback rpool/microvms/hermes-prod/persist@pre-deploy-<timestamp>`, then rolled back NixOS generation. Full VM state restored to pre-deploy snapshot. Agent state (skills, SOUL.md, sessions, memories, workspace) was restored to the snapshot taken before this deploy — any changes the agent made to its state between the snapshot and the failed deploy are LOST.",
  "next_step": "The failure may have been caused by agent state corruption (e.g., a bad SOUL.md edit or corrupt session). If the issue recurs, review recent state changes in /var/lib/hermes/.hermes/ before the next deploy."
}
```

**On failure (VM unreachable, Layer 2 rollback):**

```json
{
  "timestamp": "2026-07-04T15:33:00Z",
  "commit": "abc123def",
  "commit_subject": "Add jq to hermes-prod",
  "status": "failed",
  "deployed_to": "hermes-prod",
  "canary_output": "SSH unreachable: hermes-prod did not respond on Tailscale within 60 seconds. VM may have crashed or hung during boot.",
  "rollback_layer": 2,
  "action_taken": "Rolled back to previous microvm runner via symlink swap (`current` → `booted`) and full VM restart. The VM rebooted from the previous system closure. Agent state was NOT touched — fully preserved.",
  "next_step": "The VM failed to boot or crashed during the new config. Check `journalctl -M hermes-prod` on the host for boot errors. The config change may be incompatible with the VM's boot process."
}
```

The `action_taken` field explicitly tells the agent:
- **Which rollback layer** was used (1, 2, or 3)
- **What mechanism** ran (generation rollback, runner symlink swap, ZFS rollback)
- **Whether agent state was preserved or lost** — this is the critical
  distinction. Layers 1 and 2 preserve state; Layer 3 restores a snapshot
  and loses any state changes made since the snapshot.
- **What the agent should do next** — fix the config, investigate state
  corruption, or check boot logs

This file is written AFTER the rollback completes, so it survives even a
Layer 3 ZFS rollback (the rollback restores the pre-deploy snapshot, then
the deploy service writes the result file on top of it). The agent reads
this file on startup — a oneshot systemd service in the VM checks for it
and, if present, logs a message that the agent will see in
`journalctl -u hermes-agent`:

```nix
# In the hermes aspect (VM side):
systemd.services.hermes-deploy-notify = {
  description = "Notify agent of last deploy result";
  after = [ "hermes-agent.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig.Type = "oneshot";
  script = ''
    result="/var/lib/hermes/.hermes/deploy-results/latest.json"
    if [ -f "$result" ]; then
      status=$(jq -r .status "$result")
      if [ "$status" = "failed" ]; then
        echo "Previous deploy FAILED. See $result for details." >&2
        jq . "$result" >&2
      elif [ "$status" = "success" ]; then
        echo "Previous deploy SUCCEEDED. See $result for details." >&2
        jq . "$result" >&2
      fi
    fi
  '';
};
```

The agent's SOUL.md or a startup skill should instruct it to check
`deploy-results/latest.json` on startup. The file contains the canary
output (what went wrong), the commit hash and subject line (which change
caused the failure), the exact rollback mechanism used and whether state
was lost, and a suggested next step. This lets the agent understand *why*
its change failed, *what happened to its state*, and *how to fix it* in a
follow-up commit.

### Loop prevention

**A failed deploy is still a processed deploy.** The deploy service updates
`last-deployed` to the commit hash regardless of whether the deploy
succeeded or failed. The `last-deployed` file tracks:

```
# /var/lib/hermes-deploy/last-deployed
<commit-hash> <status>
```

Where `<status>` is `success` or `failed`. On the next poll cycle, the
deploy service compares `origin/main` against `last-deployed`:
- If they match: no new commits, do nothing (regardless of success/failed
  status)
- If they differ: new commits to process, run the deploy flow

This means a failed commit is never retried automatically. The agent is the
retry mechanism — it sees the failure in `deploy-results/latest.json`, fixes
the issue, pushes a new commit, and the deploy service picks it up as a new
undeployed commit.

**The only automatic retry is for crashes**: if the deploy service crashes
mid-deploy (before updating `last-deployed`), the next poll sees the same
commit as undeployed and retries. This is correct — the previous attempt
didn't complete. It's self-limiting because the retry either completes
(updates `last-deployed`) or fails cleanly (updates `last-deployed` with
"failed" status).

**No deploy-rollback-deploy loop is possible** because:
1. Successful deploy: `last-deployed` updated, VM running new config, no
   rollback
2. Failed QA canary: prod never touched, QA rolled back, `last-deployed`
   updated to "failed", next poll sees no new commits
3. Failed prod canary: prod rolled back, `last-deployed` updated to
   "failed", next poll sees no new commits
4. Crash mid-deploy: `last-deployed` not updated, next poll retries once,
   either succeeds or fails cleanly

**Scope**: this rollback chain runs only after a failed prod deploy. There
is no ongoing health watchdog — that's a separate concern, out of scope for
this plan. If the agent breaks itself between deploys (e.g., a bad SOUL.md
edit), the user notices via Telegram and manually triggers a rollback via
Telegram commands (`/rollback config`, `/rollback state`) or SSH.

### Separating Hermes deploy from host deploy

SSH-based `switch-to-configuration switch` only restarts changed services
inside the VM — it never touches the host. Host file changes never block VM
deploys. The deploy service always deploys VMs when guest-side config
changed, regardless of what else changed in the same commit. Host-side
changes trigger a separate Telegram alert asking for a manual host deploy.

See the change classification table in section 4 for the full matrix.

Host deploys remain manual via `nix run .#deploy-rs -- .hvn-hyp1`. The
deploy service never runs deploy-rs.

### QA → prod gate with end-to-end canary

The deploy service always updates QA before prod. After updating QA, it
runs a canary check before touching prod:

1. Build the QA toplevel on the host, SSH-switch into hermes-qa
   (only changed services restart — see section 10)
2. Wait for hermes-agent to settle (poll `systemctl is-active`, up to 30s)
3. SSH to hermes-qa (via bridge IP 10.27.50.21), run three canary checks:

   **a. Process check**: `systemctl is-active hermes-agent`
   — is the gateway process alive?

   **b. End-to-end LLM canary**:
   ```bash
   timeout 30 hermes -z "Reply with exactly: CANARY_OK"
   ```
   This sends a real query through the full stack (gateway → LLM API →
   response). If the agent responds with "CANARY_OK" (or anything at all),
   the LLM API key, model config, and gateway are all working. The
   one-shot mode (`-z`) prints only the final response text — no banner,
   no spinner, no tool previews — so the check is a simple string
   comparison. A 30-second timeout covers API latency. This costs one
   small LLM call per deploy — negligible.

   **c. Error scan**: `journalctl -u hermes-agent --since "2 min ago" -p err`
   — are there any error-level log lines since the deploy? This catches
   silent failures like a missing dependency group, a bad config key, or a
   crashed messaging adapter that didn't kill the process.

4. If all three checks pass: deploy to prod (same build + SSH-switch pattern)
5. If any check fails: run the automated rollback chain (see Rollback
   section), send Telegram alert with the failing check and relevant log
   lines, do not touch prod

**Why not just check `systemctl is-active`**: A process can be "active" while
being completely non-functional — e.g., the Telegram adapter crashed but the
gateway process didn't exit, or the LLM API key is wrong and every request
401s. The end-to-end canary catches these by actually exercising the agent.
The `hermes -z` one-shot mode is purpose-built for this: it's a single
prompt, single response, no interaction. If the LLM API is broken, the
canary fails fast (timeout or error output).

## Trust model

| Capability | Agent has? | Who controls it |
|---|---|---|
| Modify skills, SOUL.md, memory | Yes (runtime, VM state) | Agent, autonomously |
| Clone homelab, create branches, open PRs | Yes (GitHub PAT, repo:write) | Agent, autonomously |
| Auto-merge non-infra PRs | Yes (GH Actions, path-filtered) | Automated |
| Merge infra PRs | No | Human review |
| Run `microvm -u` (deploy VMs) | No | hermes-deploy.service on hvn-hyp1 |
| Run `deploy-rs` (deploy host) | No | Human, manually |
| SSH to hvn-hyp1 | No | Human only |
| Access agenix master keys | No | hvn-hyp1 only (not shared to VMs) |
| Access other hosts' secrets | No | Each VM only sees its own 3 secrets (per-VM symlink farm) |
| Install Python packages at runtime | No (sealed venv, read-only) | Git PR → merge → rebuild |
| Install system packages at runtime | No (Nix store, read-only) | Git PR → merge → rebuild |
| Modify its own NixOS config directly | No (config is in git) | Git PR → review → merge → deploy |

The agent's GitHub PAT is the most sensitive credential it holds. It's
scoped to `repo:write` on homelab only — no org access, no admin, no
ability to modify GitHub Actions workflows or secrets.

**GitHub branch protection is a hard prerequisite**: The PAT's `repo:write`
scope allows pushing directly to any branch, including `main`. Without
branch protection rules, the agent could bypass PRs entirely and push
straight to `main`, which would auto-deploy without review. The trust
model ("infra changes require human review") depends on GitHub branch
protection requiring PR review on `main`:

- Require pull request reviews before merge (at least 1 approval)
- Require status checks to pass before merge (the `nix flake check` CI)
- Restrict who can push to `main` (no direct pushes, even by repo owner)
- The agent's PAT user should NOT be a repository admin or have bypass
  permissions for branch protection

This is a GitHub-side configuration requirement, not a Nix thing. It must
be set up in the repo settings before the agent starts self-modifying.

## Files to create

### New aspects

1. **`modules/den/aspects/virtualization/microvm-host.nix`** — host-side
   microvm.nix module, `br-microvm` bridge + NAT for VM outbound, per-VM
   agenix symlink farm service, `den.schema.host` extensions for
   `microvm.guests` / `microvm.sharedNixStore`. Based on sini's
   `microvm.nix` but simplified (no GPU passthrough, no colmena).

2. **`modules/den/aspects/virtualization/microvm-guests.nix`** —
   producer/consumer pair that resolves guest entities into
   `microvm.vms.<name>` definitions. Based on sini's `microvm-guests.nix`
   but simplified (no GPU, no vfio gates, no root key injection from user
   registry — use Tailscale SSH instead).

3. **`modules/den/quirks/microvm-guests.nix`** — quirk declaration for the
   guest resolution pipeline.

4. **`modules/den/aspects/services/hermes-deploy.nix`** — the deploy
   service: webhook receiver (via Tailscale Funnel), polling timer, the
   deploy script that runs `microvm -u`, path-based classification, QA→prod
   gate, ZFS snapshot, Telegram notifications.

### Modified aspects

5. **`modules/den/aspects/services/hermes.nix`** — extend with:
   - `settings.workspace.enable` / `settings.workspace.repo` — git checkout
     for the agent to work in (persisted in `/persist`, survives restarts)
   - `settings.gitIdentity.name` / `settings.gitIdentity.email` — commit
     identity
   - `settings.extraPackages` — passthrough to
     `services.hermes-agent.extraPackages` (so the agent can PR adding
     packages to itself)
   - Support for running as a MicroVM guest (not just nspawn container):
     when `host.microvm.guest.enable` is true, emit the hermes service
     directly (no containers.hermes block)
   - Impermanence: declare explicit persist directories (NOT the whole
     `/var/lib/hermes` tree) so Nix-generated `config.yaml` and `.env`
     are NOT persisted (they'd drift from the system closure on rollback):
     ```nix
     persist.directories = [
       "/var/lib/hermes/.hermes/skills"
       "/var/lib/hermes/.hermes/SOUL.md"  # actually a file, use persist.files
       "/var/lib/hermes/.hermes/sessions"
       "/var/lib/hermes/.hermes/memories"
       "/var/lib/hermes/.hermes/cron"
       "/var/lib/hermes/workspace"
       "/var/lib/tailscale"
     ];
     ```
     The workspace persists across VM restarts so the agent's uncommitted
     git work is not lost during a deploy.
   - Graceful drain: set `agent.restart_drain_timeout = 120` in the
     default settings so the gateway drains active conversations before
     restart. Sessions are marked `resume_pending` and recovered on next
     boot.
   - Deploy result notification: a oneshot systemd service
     (`hermes-deploy-notify`) that checks for
     `/var/lib/hermes/.hermes/deploy-results/latest.json` on startup and
     logs the result to stderr (visible in `journalctl -u hermes-agent`).
     This tells the agent whether its last PR deployed successfully or
     failed (with canary output and suggested fix).
   - Agent bootstrap: three idempotent oneshot services (workspace clone,
     gh auth, git config) — see section 11.

6. **`modules/den/aspects/core/network/tailscale.nix`** — add `authKeyFile`
   support. The existing aspect (created earlier in this session for
   hvn-hyp1) does not use `authKeyFile` (interactive auth). The MicroVMs
   need headless auth via `services.tailscale.authKeyFile` pointing to the
   agenix-provisioned key. The aspect should conditionally set
   `authKeyFile` when a `tailscale-auth-key` secret is present in the
   host's `secretRequests`. This also requires a separate tailscale auth
   key secret per VM (see New secrets below). The migration to
   `authKeyFile` for existing hosts (hvn-hyp1) is out of scope for this
   plan — the aspect change should be backwards-compatible (authKeyFile
   only set when the secret exists).

### New hosts

7. **`modules/den/hosts/hermes-prod/default.nix`** — prod MicroVM guest
   entity. Produces a standalone `nixosConfiguration` output (does NOT use
   `intoAttr = [ ]` — see section 1 for why). Sets `deployment.enable =
   false` so it's excluded from deploy-rs nodes. Aspect includes:
   - `disk.impermanence` — persist bind-mounts (ZFS rollback guard skips
     since VM has no ZFS aspect)
   - `secrets.agenix` — secret delivery via virtiofs share
   - `services.hermes` — the agent + bootstrap oneshots
   - `core.network.tailscale` — admin SSH access
   - `core.security.openssh` — deploy service SSH access (directly, NOT via
     `roles.server` which pulls in crowdsec — redundant since the host
     already runs crowdsec, and wasteful inside a single-purpose VM)

   Aspects NOT included (and why):
   - `roles.server` — pulls in crowdsec + firewall bouncer. Redundant: the
     host (hvn-hyp1) already runs crowdsec, and the VM is behind the host's
     NAT. Running crowdsec inside the VM wastes resources.
   - `core.base` — enables `boot.initrd.systemd.emergencyAccess` and adds
     `bottom`/`lnav` to systemPackages. Unnecessary in a headless VM with
     no physical console. The `deployment.*` options it defines aren't
     needed since `deployment.enable = false`.
   - `core.users.home-manager` — no human users, no interactive shells.
     The `hermes` user created by the hermes module doesn't need a
     home-manager-managed home.
   - `core.users.shell` — no interactive shell configs needed.

   Note: `den.schema.host.includes` auto-applies `core.nix`,
   `core.nix.stateVersion`, `core.localization.time`, `core.security.sudo`,
   `core.users.*`, `networking.default`, `core.network.firewall-collector`,
   `core.secrets.collector`. Some of these are heavier than needed for a
   MicroVM (home-manager, sudo, resolved with DNS-over-TLS). The
   implementing agent should evaluate whether to exclude specific
   auto-applied aspects via `den.schema.host.excludes` or accept them as
   harmless overhead. At minimum, `networking.default` is needed for
   basic network setup (it reads `host.networking.interfaces` and emits
   systemd-networkd config), but its DNS-over-TLS + resolved setup is
   overkill for a VM that just needs to resolve API hostnames.

   Declares microvm guest config (cloud-hypervisor, tap interface, vcpu,
   mem, shares, writable store overlay, persist share, agenix share).

8. **`modules/den/hosts/hermes-qa/default.nix`** — QA MicroVM guest,
   same structure, different IP/MAC/bot/resources.

### Modified hosts

9. **`modules/den/hosts/hvn-hyp1/default.nix`** — add
   `den.aspects.virtualization.microvm-host` to includes, add
   `microvm.guests = [ hermes-prod hermes-qa ]` to host entity, add
   `den.aspects.services.hermes-deploy` to includes. Remove the nspawn
   container config (replaced by MicroVMs).

### New secrets

10. **`.secrets/hosts/hermes-prod/hermes-env.age`** —
   `OPENROUTER_API_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`

11. **`.secrets/hosts/hermes-prod/hermes-github-pat.age`** — GitHub PAT
    (repo:write on homelab)

12. **`.secrets/hosts/hermes-prod/tailscale-auth-key.age`** — Tailscale
    auth key for hermes-prod VM

13. **`.secrets/hosts/hermes-qa/hermes-env.age`** — same structure,
    different bot token

14. **`.secrets/hosts/hermes-qa/hermes-github-pat.age`** — separate PAT

15. **`.secrets/hosts/hermes-qa/tailscale-auth-key.age`** — Tailscale
    auth key for hermes-qa VM

16. **`.secrets/hosts/hvn-hyp1/hermes-deploy-pat.age`** — read-only PAT
    for the deploy service to fetch from GitHub

17. **`.secrets/hosts/hvn-hyp1/github-webhook-secret.age`** — GitHub
    webhook secret for signature validation

### New CI

18. **`.github/workflows/hermes-check.yml`** — `nix flake check` on PRs
    touching hermes-related paths. GitHub-hosted runner, no SSH.

19. **`.github/workflows/hermes-auto-merge.yml`** — auto-merge PRs that
    only touch `documents/**` paths. Uses `gh pr merge --squash --auto`.
    GitHub-hosted runner, no SSH.

## Implementation order

The strategy is to build the QA MicroVM end-to-end while prod stays on the
existing nspawn container. Prod is only touched after QA proves the full
pipeline works. This means hermes-prod (nspawn) and hermes-qa (MicroVM)
run side-by-side temporarily — different Telegram bots, different
Tailscale nodes, no interference.

### Phase 1: MicroVM infrastructure (no VMs yet)

Just the plumbing — host-side aspects, networking, flake input. No VMs
are created. Prod nspawn continues running.

1. Add `microvm.nix` flake input to `modules/meta/inputs.nix`
2. Create `modules/den/aspects/virtualization/microvm-host.nix` (host
   module, br-microvm bridge + NAT, per-VM agenix symlink farm, schema
   extensions for `microvm.guests` / `microvm.sharedNixStore`)
3. Create `modules/den/aspects/virtualization/microvm-guests.nix`
   (producer/consumer pair for guest resolution)
4. Create `modules/den/quirks/microvm-guests.nix`
5. `git add` new files, `nix run .#write-flake --impure`
6. Add `den.aspects.virtualization.microvm-host` to hvn-hyp1's includes
   (with `microvm.guests = [ ]` — no guests yet)
7. Deploy hvn-hyp1 with `nix run .#deploy-rs -- .hvn-hyp1`
8. Verify: `microvm list` shows no VMs, `ip addr show br-microvm` shows
   the bridge at 10.27.50.1/24, NAT rules are in place, host is healthy,
   prod nspawn hermes still running

### Phase 2: QA VM (first MicroVM)

Create the QA guest, provision secrets, boot it. No deploy service yet —
deploy QA manually via SSH switch to test the mechanism.

9. Create `modules/den/hosts/hermes-qa/default.nix` (guest entity, QEMU
   config, networking, aspects — see "Files to create" #8)
10. Extend `modules/den/aspects/services/hermes.nix` with MicroVM guest
    support (no `containers.hermes` block when `microvm.guest.enable`),
    impermanence persist dirs, graceful drain, bootstrap oneshots
11. Create `.secrets/hosts/hermes-qa/hermes-env.age` (throwaway API key +
    test Telegram bot token + your Telegram user ID)
12. Create `.secrets/hosts/hermes-qa/hermes-github-pat.age` (separate PAT,
    repo:write scope)
13. `agenix rekey`
14. Add `hermes-qa` to hvn-hyp1's `microvm.guests`
15. Authorize the deploy service's SSH key on hermes-qa (for manual SSH
    deploys during testing — the deploy service doesn't exist yet, so use
    your own SSH key for now)
16. Deploy hvn-hyp1 — the QA VM auto-provisions on first deploy
17. Verify QA VM basics:
    - `microvm list` shows hermes-qa as active
    - SSH to 10.27.50.21 works
    - `tailscale status` shows hermes-qa online (auto-authenticated via
      authKeyFile)
    - SSH via Tailscale hostname works (for admin access)
18. Verify hermes-agent on QA:
    - `systemctl is-active hermes-agent` → active
    - `hermes version` works
    - Send a message to the QA Telegram bot → agent responds
    - `hermes -z "Reply with exactly: CANARY_OK"` → returns CANARY_OK
19. Test manual SSH deploy to QA:
    - Make a trivial change to hermes-qa's config (e.g., add a comment)
    - `nix build .#nixosConfigurations.hermes-qa.config.system.build.toplevel`
    - `ssh 10.27.50.21 "$(readlink result)/bin/switch-to-configuration switch"`
    - Verify only hermes-agent restarted (or nothing if the change was
      trivial), VM stayed up
20. Test `microvm -u` fallback:
    - Stop the QA VM: `systemctl stop microvm@hermes-qa`
    - `microvm -u hermes-qa && systemctl start microvm@hermes-qa`
    - Verify VM boots and hermes-agent comes back up
21. Test impermanence:
    - Create a test file in `/var/lib/hermes/.hermes/skills/test.md`
    - Restart the VM (`systemctl restart microvm@hermes-qa`)
    - Verify the file still exists after restart (persisted via `/persist`)
    - Verify `/var/lib/hermes/.hermes/config.yaml` was regenerated (not
      persisted)

### Phase 3: Deploy service (QA only)

Build the deploy service and point it at QA only. Prod stays on nspawn —
the deploy service doesn't know about prod yet.

22. Create `modules/den/aspects/services/hermes-deploy.nix` (webhook
    receiver, polling timer, path classification, build + SSH switch,
    canary, Telegram notifications, deploy result file)
23. Create `.secrets/hosts/hvn-hyp1/hermes-deploy-pat.age` (read-only PAT
    for fetching from GitHub)
24. Create `.secrets/hosts/hvn-hyp1/github-webhook-secret.age`
25. Configure Tailscale Funnel on hvn-hyp1 (`tailscale funnel on`)
26. Add `den.aspects.services.hermes-deploy` to hvn-hyp1's includes
27. Deploy hvn-hyp1
28. Configure GitHub repo webhook: URL =
    `https://hvn-hyp1.<tailnet>.ts.net/hooks/github`, content-type = json,
    secret = value from agenix
29. **Test happy path**: push a trivial change to hermes-qa's config on
    main. Verify:
    - Webhook fires → deploy service starts
    - Build on host → SSH switch to QA → only changed services restart
    - Canary passes (process active + `hermes -z CANARY_OK` + no errors)
    - Telegram notification: "Deployed to hermes-qa"
    - `deploy-results/latest.json` written with status=success
30. **Test webhook fallback**: stop the webhook service, push another
    change. Verify the polling timer catches it within 2 min and deploys.
31. **Test canary failure + rollback**: push a change that breaks QA
    (e.g., invalid model name). Verify:
    - Canary fails (hermes -z times out or errors)
    - Rollback chain runs (Layer 1: generation rollback)
    - Canary re-passes after rollback
    - Telegram notification: "QA canary failed, rolled back (Layer 1)"
    - `deploy-results/latest.json` written with status=failed, canary
      output, rollback_layer=1
    - `last-deployed` updated to the failed commit (no retry loop)
32. **Test loop prevention**: push the SAME breaking commit again (or
    just verify `last-deployed` matches `origin/main`). Confirm the
    deploy service does nothing — no retry, no loop.

### Phase 4: Prod VM (side-by-side with nspawn)

Create the prod MicroVM. Both prod nspawn and prod MicroVM run
temporarily — different Telegram bots, so no conflict. The deploy service
now handles QA→prod (with the canary gate).

33. Create `modules/den/hosts/hermes-prod/default.nix` (same structure as
    hermes-qa, different IP/MAC/resources)
34. Create `.secrets/hosts/hermes-prod/hermes-env.age` (real API key +
    prod Telegram bot — can reuse the same bot as nspawn, or create a new
    one; if reusing, stop the nspawn container first to avoid two
    processes polling the same bot)
35. Create `.secrets/hosts/hermes-prod/hermes-github-pat.age` (separate
    PAT, repo:write scope)
36. `agenix rekey`
37. Add `hermes-prod` to hvn-hyp1's `microvm.guests`
38. Deploy hvn-hyp1 — prod VM auto-provisions
39. Verify prod VM:
    - `microvm list` shows both hermes-prod and hermes-qa
    - SSH to 10.27.50.20 works
    - Tailscale auto-authenticated
    - `hermes version` works
    - Telegram bot responds
    - `hermes -z "Reply with exactly: CANARY_OK"` → CANARY_OK
40. **Test the full QA→prod pipeline**: push a trivial change to
    hermes-prod's config. Verify:
    - Deploy service builds QA first, canary passes
    - Then builds prod, SSH switches, canary passes
    - Telegram notifications at each step
    - `deploy-results/latest.json` on prod VM shows status=success
41. **Test prod rollback**: push a breaking change to prod. Verify:
    - QA canary fails → prod is NOT touched
    - QA rollback runs
    - Telegram: "QA canary failed, prod NOT deployed"
    - Prod nspawn (if still running) is unaffected

### Phase 5: Cut over (remove nspawn)

Now that the prod MicroVM is proven, remove the nspawn container.

42. Stop the nspawn container: `nixos-container stop hermes` on hvn-hyp1
    (if the Telegram bot is shared, do this before starting the prod VM's
    bot — or use separate bots and skip this step until after)
43. Remove the nspawn container config from `modules/den/hosts/hvn-hyp1/`:
    - Remove `den.aspects.services.hermes` from hvn-hyp1's includes (the
      aspect now only emits the MicroVM guest config, not the nspawn
      container — but hvn-hyp1 shouldn't include the hermes service
      aspect at all since it runs as a MicroVM guest, not on the host)
    - Remove any nspawn-specific config
44. Deploy hvn-hyp1 — the nspawn container is removed, prod MicroVM
    continues running
45. Verify: `nixos-container list` shows no hermes container, prod MicroVM
    still healthy, Telegram bot still responding

### Phase 6: CI + auto-merge + GitHub config

46. Set up GitHub branch protection rules on main (require PR review,
    require status checks, restrict direct pushes). Can be done manually
    in repo settings or via a `nix run .#configure-github` script.
47. Create `.github/workflows/hermes-check.yml` (`nix flake check` on PRs
    touching hermes-related paths)
48. Create `.github/workflows/hermes-auto-merge.yml` (auto-merge PRs that
    only touch `documents/**` paths)
49. **Test auto-merge**: agent (or you) opens a non-infra PR (e.g., a
    USER.md in `documents/`). Verify GH Actions auto-merges, deploy
    service picks it up, VM restarts with the new doc.
50. **Test infra review gate**: agent opens an infra PR (e.g., adding jq
    to extraPackages). Verify GH Actions does NOT auto-merge, posts a
    review request comment.

### Phase 7: ZFS snapshots + rollback automation

51. Add pre-deploy ZFS snapshot step to the deploy service: before
    deploying to prod, snapshot the persist dataset
    (`zfs snapshot rpool/microvms/hermes-prod/persist@pre-deploy-<ts>`)
52. Implement the full automated rollback chain (Layer 1 → Layer 3, or
    Layer 2 → Layer 3 if SSH unreachable) in the deploy service
53. **Test Layer 3 rollback**: push a change that corrupts agent state
    (e.g., a bad SOUL.md that makes the agent hallucinate). Verify:
    - Layer 1 (generation rollback) doesn't fix it (config is fine)
    - Layer 3 (ZFS snapshot rollback) restores agent state
    - Agent comes back healthy
    - `deploy-results/latest.json` shows rollback_layer=3, action_taken
      explains state was lost
54. Add manual Telegram rollback commands (`/rollback config`, `/rollback
    state`, `/rollback vm`) for when the agent breaks itself between
    deploys (no automated watchdog — see scope note in Rollback section)

## Technical risks and unknowns

These are assumptions in the plan that need verification during
implementation. They are not blocking the plan but could change the
approach if they don't hold.

1. **cloud-hypervisor + writableStoreOverlay**: The plan uses
   cloud-hypervisor with `writableStoreOverlay`. microvm.nix's overlay
   support is tested primarily with QEMU. If cloud-hypervisor doesn't
   handle the overlayfs assembly correctly in the initrd, fall back to
   QEMU. Verify during Phase 2.

2. **registerClosure + writableStoreOverlay**: The microvm.nix docs note
   these "may be incompatible with a persistent writable store overlay."
   Our overlay is NOT persistent (it's a volume that resets on boot), so
   the stale-registration concern may not apply. But if `nix-store
   --load-db` conflicts with the overlay, disable `registerClosure` and
   rely on the overlay's own path registration. Verify during Phase 2.

3. **Impermanence in the MicroVM**: The VM uses the existing
   `disk.impermanence` aspect (same as the hosts). The ZFS rollback part
   is gated on `host.hasAspect den.aspects.disk.zfs` and correctly skips
   for the VM (no ZFS inside the VM). The remaining question is whether
   impermanence's bind-mounts work correctly when `/persist` is a virtiofs
   share and the root is an overlayfs (`/nix/.ro-store` + `/nix/.rw-store`).
   The impermanence module creates mount targets on the root and
   bind-mounts from `/persist` — this should work regardless of whether
   the root is overlayfs or a normal filesystem, but is unverified with
   this exact configuration. Verify during Phase 2.

4. **Graceful drain on pinned rev**: The drain mechanism
   (`agent.restart_drain_timeout`, `resume_pending` sessions) is verified
   against the current hermes-agent main branch. The pinned rev (`6dfb832`,
   2026-06-25) may or may not have this feature. Verify by checking
   `hermes config` or the changelog for the pinned rev. If absent, the
   drain timeout config key will be silently ignored and restarts will be
   hard kills (sessions lost). Not a blocker — the agent's state
   (skills, SOUL.md, memories) still persists via `/persist`; only
   in-flight conversations would be lost.

5. **Tailscale Funnel availability**: The webhook receiver depends on
   Tailscale Funnel being available on the tailnet. Funnel requires
   enabling in the Tailscale admin console and may have node limits on
   free plans. If Funnel is unavailable, fall back to polling-only (every
   2 min) — the plan already includes this as a fallback.

6. **SSH to VMs via bridge IP**: The deploy service and canary checks SSH
   to the VMs via bridge IPs (10.27.50.20/21), not Tailscale. This requires
   the deploy service's SSH key to be authorized in the VM's
   `users.users.root.openssh.authorizedKeys` (or a dedicated deploy user).
   The hermes aspect or microvm-guests aspect should inject the deploy
   service's public key into the guest config.

## Open questions

1. **Hermes hermes-agent rev pin**: currently pinned at `6dfb832` (last
   working Nix build). When (if) Nix support is restored upstream, bump the
   pin. Until then, the agent runs on 0.17.0 with no updates.

2. **QA Telegram bot**: needs a separate bot token from @BotFather. The QA
   bot should only respond to the same `TELEGRAM_ALLOWED_USERS` as prod, but
   with a clear "QA" indicator in its name/description so messages don't
   get confused.

3. **Deploy service Telegram notifications**: resolved — the deploy service
   reuses the prod bot token and sends directly via the Telegram Bot API
   (curl). Same chat as agent messages, works when hermes is down. See
   section 12. Matrix notifications can be added later as a second channel.

4. **Tailscale auth key strategy**: one reusable auth key for both VMs, or
   one per VM? Reusable is simpler (one secret to manage) but means a
   compromised key can register arbitrary nodes. Per-VM is more secure.
   Recommend per-VM since the secrets are agenix-managed anyway.

5. **VM resource sizing**: prod at 4 vCPU / 8 GB is a guess. The agent's
   main resource consumers are the Python venv (sealed, in /nix/store) and
   the nix eval/build inside the VM (needs RAM for evaluation). Monitor
   actual usage and adjust. QA at 2 vCPU / 4 GB should be sufficient for
   validation.

6. **Writable store overlay size**: 4 GB for the nix store overlay may not
   be enough if the agent runs `nix build` (as opposed to just `nix eval`).
   `nix eval` doesn't write to the store; `nix build` does. If the agent
   needs to build derivations inside the VM, increase to 8-16 GB. The
   overlay is ephemeral (not persisted), so it resets on each VM restart.

7. **Drain timeout tuning**: `agent.restart_drain_timeout = 120` (2 min)
   is a starting guess. If the agent regularly runs tool calls longer than
   2 minutes (e.g., long shell commands, file operations), increase it. If
   deploys are too slow because the drain always waits the full timeout,
   decrease it. The drain only waits as long as there are active sessions —
   if the gateway is idle, it exits immediately. Monitor
   `journalctl -u hermes-agent | grep "drain"` to see actual drain times.

8. **Canary LLM cost**: the QA canary runs one `hermes -z` query per deploy,
   which costs one small LLM API call. At ~$0.001 per call for a cheap
   model, this is negligible even with daily deploys. But the QA VM should
   use a cheap model (not the same expensive model as prod) to keep canary
   costs down.

9. **What happens if the deploy service is down?**: VMs keep running on
   their last-good config. When the deploy service comes back, the polling
   timer catches up on all missed commits (git fetch + diff from
   last-deployed commit). The last-deployed commit hash + status is tracked
   in `/var/lib/hermes-deploy/last-deployed` on hvn-hyp1. Webhooks that
   arrived while the service was down are lost (GitHub doesn't retry), but
   the polling timer catches the same commits within 2 minutes. Failed
   deploys are not retried automatically — the agent must push a new commit
   (see Loop prevention).

10. **Deploy result file persistence across Layer 3 rollbacks**: the deploy
    result file is written to the persist share AFTER the rollback
    completes, so it survives even a ZFS snapshot rollback (the rollback
    restores the pre-deploy snapshot, then the result is written on top).
    But if the deploy service crashes between the rollback and writing the
    result, the agent won't know why the deploy failed. The Telegram
    notification to the user is sent before the result file is written, so
    the user always knows — the agent might not. Mitigation: the agent can
    also check `git log --oneline -5` in its workspace to see if its PR was
    merged but the deploy result file is missing (indicating a crash during
    rollback).
