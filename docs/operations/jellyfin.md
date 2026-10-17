# Jellyfin operations

Jellyfin runs in the `jellyfin` namespace on the compute guest. Before the
server starts, the `provision` initContainer prepares retained state. The
`jellyfin-configuration` Job then applies the declared libraries and
settings. Its API-key bootstrap waits for the native `Healthy` response:
HTTP 200 alone also includes `Degraded` while the stock server starts.

In the commands below, set `system` to the host system and `instance` to the
compute guest listed under "Current stack" in
[`docs/operations.md`](../operations.md).

## Household directory sign-in

The household integration declares a `plugins` initContainer using the same
`jellyfin-provisioner-image` as fresh-state provisioning, with the explicit
`jellyfin-install-plugins` command. The normal Linux flake package
`jellyfin-ldap-plugin` supplies the Nix-pinned official LDAP Authentication v24
files and installer bundled in that producer; no additional helper image or
registry namespace is needed. Deployment requires a selected verified release
containing that installer, not merely an updated producer in the checkout.
Installation runs after fresh-state provisioning and before the stock runtime.
Jellarr configures only declared settings of the loaded plugin through its
native API, preserving plugin-owned user links. Do not install another version
through the dashboard or disable TLS verification.

Enroll people as described in [Identity operations](identity.md#household-media-credentials).
Use the ordinary Jellyfin username/password login, and Seerr's ordinary
Jellyfin login, with the person's primary password or separate POSIX password.
This is LDAP authentication, not OIDC, and LDAP itself does not perform MFA.

The declared Jellyfin administrator remains local, with its existing agenix
password and user ID. A same-named Kanidm account does not convert it; its
directory password cannot log in to that local account. A different central
administrator can obtain a directory-backed Jellyfin administrator account.
If Kanidm is down, directory login fails and the local administrator still
works.

Only `jellyfin-users` or `homelab-admin` membership permits directory sign-in;
outsiders are refused without creating a Jellyfin account. Membership and
directory-backed administration are checked again at each sign-in. Removing
membership denies fresh sign-in but does not revoke established sessions:
an existing session can still return HTTP 200 with the same Jellyfin user ID.

Before deploying directory integration, select a genuinely published and
anonymously verified helper release containing the LDAP installer and Kanidm
`policies.json` reconciliation, as described in "Deliver helper images".
Do not derive consumer digests from the current producers or import their
archives to bypass selection. Publication and selection do not authorize
account enrollment, policy activation or auth rollout.
Keep Seerr in phase `initial` until the owner accepts household sign-in from
an actual media client and Seerr and separately approves the live transition.
Disposable fixture success is not production acceptance; live household
acceptance remains open.

To roll back directory integration, revert the plugin initContainer and
Jellarr LDAP settings together and restart Jellyfin. Preserve retained users,
plugin configuration and credentials; do not reset `/config` or convert
directory users to local accounts. Revert Kanidm listener/policy declarations
only after directory consumers are removed.

### Disposable household acceptance

The native `household-sign-in-runtime` flake app and CI lane materialize the
same Python suite and committed manifests. The Jellyfin provisioner, Kanidm
provisioner and Jellarr use actual selected immutable verified GHCR identities
and normal registry pulls, not local archives, preloads or compatibility aliases.
Updating an unselected producer must not change those consumer identities.
They run against real pinned services in an owned disposable Docker fixture,
not on the production host and not inside a new Docker VM test envelope.

Run as root on disposable native x86_64 Linux with a running Docker daemon.
Reserve the fixture's workload names, state and loopback ports for the suite.
Before starting, the canonical hostname `idm.plus2.danielvicory.dev` must
resolve to `127.0.0.1` on that host. The app never edits host resolution.
The disposable GitHub runner may explicitly add that loopback hosts entry;
do not redirect the production hostname on a production host.

This application lane exercises authentication and certificate verification.
The directory K3s/kernel VM gate separately proves NetworkPolicy enforcement;
Docker success cannot prove that boundary. These instructions do not record
a pass for the revised packaging or native lane, and neither fixture replaces
owner-approved deployment and real-device household acceptance.

## Storage

- `/config` is the retained `jellyfin-config` volume. It holds users,
  settings and the database. Its host path is listed under "Retained state"
  in [`docs/operations.md`](../operations.md).
- `/media` is the guest's `/srv/media/data/library`, mounted read-only.
  Jellyfin cannot change the library.
- `/cache` is disposable, up to 64 GiB, and is deleted with the Pod.
  Transcodes go to `/cache/transcodes`. If `/cache` passes 64 GiB,
  Kubernetes evicts the Pod and playback stops.
- The cache size assumes two Jellyfin settings that Jellarr cannot manage, so
  they live in Jellyfin's retained configuration. After restoring or
  recreating `/config`, set them again in Dashboard → Playback → Transcoding:
  - **Throttle transcodes**, with a throttle delay of 300 seconds.
  - **Delete segments**, keeping 900 seconds of segments.

  Without them Jellyfin keeps every segment until playback stops, and one 4K
  remux can need its whole file. With them each stream holds about 1200
  seconds of segments, so 64 GiB covers four 4K streams at about 100 Mb/s.

## Hardware transcoding

Jellyfin transcodes with Intel QSV on the host's Arc GPU. The host drives the
GPU with the `i915` driver and its own firmware. The compute guest receives
only the GPU's render node, `/dev/dri/renderD128`, which carries group
`gpu-render` (GID 506), mode `0660`. Jellyfin is the only workload that holds
that group and mounts the guest's `/dev/dri`. On the host, the render node is
group `render`, mode `0660`, and no host user is in `render`.

The transcoding mode is declared as
`den.clusters.prod-home.settings.kubernetes.services.jellyfin.transcoding`:
`hardware` (the default) or `software`. The `jellyfin-configuration` Job
applies it. Jellarr writes only the encoding keys it declares. Throttling and
segment deletion (see "Storage"), tone mapping, and every other encoding
setting stay as they are set in Jellyfin.

### When the GPU is missing

- The compute guest, Kubernetes, the other workloads and Jellyfin keep
  running. Direct play keeps working.
- A transcode fails with a playback error, and Jellyfin's ffmpeg log records
  the device error. Jellyfin does not fall back to software.
- If Jellyfin's own settings use hardware decoding for trickplay or thumbnail
  extraction, those tasks fail too.
- When the render node returns, Incus adds it to the guest. Jellyfin uses it
  no later than its next start; to apply it now, delete the Pod.
- After some host boots the GPU has no driver: only `xe` loaded, and it
  declines DG2. The check reports the node missing on the host. Load the
  driver by replaying the device's add event:

  ```sh
  sudo udevadm trigger --action=add /sys/bus/pci/devices/0000:85:00.0
  ```

### Check hardware acceleration

Run the check as root on the host, from the repository revision in service.
It reads state only and needs no playback:

```sh
sudo bash docs/operations/jellyfin-acceleration-check.sh
sudo bash docs/operations/jellyfin-acceleration-check.sh --transcode
```

It prints the declared acceleration type, then `STATE` and `REASON`:

| State | Meaning | Exit |
| --- | --- | --- |
| `usable` | Jellyfin opens the render node and the Intel iHD driver lists encode profiles. With `--transcode`, a 5-second QSV test encode also succeeded. | 0 |
| `software` | Software transcoding is declared. This is not a fault. | 0 |
| `degraded` | Hardware mode is declared and Jellyfin cannot use the GPU. `REASON` names the first failed step, and the check prints host facts: the host render nodes, the PCI device and driver behind `renderD128`, `compute-accelerator-source.service`, the Incus device, and the guest's `/dev/dri`. | 1 |

`compute-accelerator-source.service` fails, with a `DRIFT` line in its log,
when `renderD128` on the host no longer belongs to the declared PCI device.
The guest would then receive the wrong device. Find which device took the
name before you change anything:

```sh
systemctl status compute-accelerator-source.service
readlink -f /sys/class/drm/renderD128/device
```

### Switch to software and back

1. Set `transcoding = "software";` for Jellyfin in the prod-home cluster
   settings.
2. Regenerate the manifests, commit, and let Argo sync. The Job sets the
   acceleration type to `none`.
3. Run the check. Expected result: `STATE: software`.

To switch back, remove the setting (or set `"hardware"`), sync, and run the
check with `--transcode`. Expected result: `STATE: usable`.

### Roll back the grant

Always in this order:

1. Declare software mode and sync, as above.
2. Remove the `/dev/dri` mount and the `gpu-render` group from the Jellyfin
   Deployment, and sync.
3. Native preseed removes nothing, and the adoption gate refuses a profile
   device that is not declared. Remove the device by hand while holding the
   lifecycle lock:

   ```sh
   sudo sh -c 'exec 9>/run/lock/compute-compute-compute-1.lock; flock 9;
     incus --project compute profile device remove compute-1 gpu-render'
   ```

4. Remove `accelerator` from the host's compute settings and
   `compute.provides.accelerator` from its includes, and activate the host.
   Preseed sets `restricted.devices.unix-char` back to `block`.

Never remove the device while QSV is declared: every transcode then fails.
The host's render-node rule can be reverted on its own; it does not affect
the guest.

### Deploy the accelerator grant

The grant spans the host, the guest and the manifests. Argo syncs `main`
automatically, so run steps 1 and 2 from the pull request's revision before
merging. If the merge comes first, Argo can recreate Jellyfin with the
`/dev/dri` mount before the guest has that directory, and Jellyfin cannot
start.

1. Activate the host. Activation installs the render-node rule and starts
   `compute-accelerator-source.service`; native preseed allows character
   devices in the project and adds the `gpu-render` device to the running
   guest without a restart. Confirm `ls -l /dev/dri/renderD128` on the host
   shows group `render`, `crw-rw----`, and
   `sudo incus --project compute exec "$instance" -- ls -ln /dev/dri` shows
   GID 506, `crw-rw----`. A udev rule change applies to an existing node only
   after `sudo udevadm trigger --subsystem-match=drm`, or after the next boot.
2. If the guest predates the boot-time `/dev/dri` directory, update it with
   the new bundle (`compute-guest replace`, in
   [`docs/operations.md`](../operations.md)). This is a guest filesystem
   migration, not helper-image delivery. Without it, a guest that restarts
   while the GPU is missing has no `/dev/dri`, and Jellyfin cannot start.
3. Merge. Argo syncs; Jellyfin restarts with the render node and the
   `gpu-render` group, and the Job applies QSV.
4. Accept hardware transcoding, below.

### Accept hardware transcoding

Stand-in tests prove the plumbing only. After the first deployment, and after
every Jellyfin release, kernel or driver change, accept on `hvn-hyp1`:

1. Run the check with `--transcode`. Expected result: `STATE: usable`.
2. List the driver's profiles:

   ```sh
   sudo incus --project compute exec "$instance" -- k3s kubectl -n jellyfin \
     exec deployment/jellyfin -c jellyfin -- \
     /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128
   ```

   Expected result: the iHD driver, and DG2 decode (`VAEntrypointVLD`) and
   encode (`VAEntrypointEncSlice`) profiles for H.264 and HEVC.
3. In a client, force a 1080p H.264 transcode of a 4K HEVC 10-bit file.
   Jellyfin's playback info must show hardware decoding and encoding. On the
   host, `sudo intel_gpu_top` must show the Video engine busy, and
   `kubectl -n jellyfin top pod` must show Jellyfin within its 2-CPU limit.
4. Play a file with graphical subtitles burned in. It must play smoothly.
   Record Jellyfin's CPU use.
5. Confirm the node modes with `ls -l /dev/dri/renderD128` on the host
   (group `render`, `crw-rw----`) and in the guest (`ls -ln`: GID 506,
   `crw-rw----`).

Record the results in the change or upgrade pull request.

## Before deployment

1. Encrypt and rekey a strong, unique password for the declared Jellyfin
   administrator as `jellyfin--jellyfin-admin--password` for the compute
   guest.
2. When you restore initialized `/config`, use that state's existing
   administrator password. The secret does not reset it.

The administrator name may use ASCII letters, digits, spaces (not leading or
trailing), and `_ . ' @ + -`. Evaluation rejects other names. If the password
secret is missing, provisioning fails and Jellyfin does not start.

## Deliver helper images

All four Nix-built helpers use the immutable GHCR digests in
`assets/helper-release/verified.json`. Kubernetes pulls them normally; routine
helper updates need no image import, guest activation or replacement.

The [main helper candidate lane](../../.github/README.md#required-green-main-nix-helper-candidates)
builds the existing Jellyfin provisioner and Jellarr alongside the retained
directory and Kanidm helpers. It publishes automatically only from an exact
merged-main push after all required CI succeeds, without a per-release approval
click. It checks source/run/attempt, archive/config/rootfs/platform identity
and anonymous access to immutable manifest digests. It does not automatically
select a release; required tests, review and a separately approved consumer
merge still govern selection.
New package visibility must be made public through the explicitly approved
GitHub operation before anonymous verification can succeed; public visibility
is irreversible.

Before publication, content audits inspect every Docker manifest-selected layer
regardless of its filename, plus image configuration and metadata. Public
certificate PEMs are allowed; private keys, credential directories and encrypted
production-secret inputs are refused.

Keep selected and supported rollback versions and layers in GHCR without
automatic pruning. Keep their reviewed source and digest mappings. CI transfer
artifacts expire and are not backups; there is no second archive store or
promise of offline/exact-digest reconstruction. If a version is lost, rebuilding
needs its locked sources/inputs and may produce a different digest. During a
registry outage, a selected uncached image must fail visibly, not run a mutable
fallback. Explicit rollback selects a previous still-available verified release
through the reviewed application path, not guest recreation or activation.

To select a release:

1. Choose an exact successful main run whose Required CI and all helper
   publication and anonymous verification jobs passed. Publication is not
   selection; leave existing consumers unchanged while preparing producers.
2. Download that run's `helper-verified-<source SHA>` artifact into a temporary
   directory. Set `run` and `sha` to the reviewed run and source:

   ```sh
   release_dir=$(mktemp -d) || exit 1
   gh run download "$run" --repo dvicory/homelab \
     --name "helper-verified-$sha" --dir "$release_dir"
   ```

3. Review its source/run, native system and four repository/digest identities.
   Copy its unmodified `verified.json` to
   `assets/helper-release/verified.json`, then remove the temporary directory.
   Do not reconstruct a selection from mutable tags or a publication-only
   receipt. The committed record keeps the original producer identities;
   they need not match producers in the new checkout.
4. Regenerate manifests, run the affected contracts and real consumer checks,
   and submit the selection for review. Merge is a separate rollout decision:
   main-tracking Argo reconciles the selected images. Runtime Secrets remain
   in their existing delivery flow.
   Helper-only upgrades and rollbacks rerun the application's provisioning hook
   even when its desired configuration is unchanged.

## Upgrade Jellyfin

The provisioner and stock server must use one reviewed release. Prepare the
producer first, then select it only after normal main publication verifies it:

1. In `pkgs/by-name/jellyfin-provisioner-image/package.nix`, set `version`,
   `sourceRev` and its source hash, `runtimeImage`, and the
   architecture-specific `runtimeDigest` for the same upstream release.
   `version` also selects the nixpkgs-multiverse Jellyfin build.
2. Confirm that `provision.patch` still applies, and update it and
   `provisionPatchRev` together. When upstream ships an equivalent Provision
   mode, remove the patch and keep the initContainer and the stock server as
   they are.
3. Leave `assets/helper-release/verified.json` and the selected consumer release
   unchanged in the producer PR. After its separately approved merge, wait for
   the normal main workflow to publish and anonymously verify the new release.
4. In the consumer PR, select that verified record as above and update the
   reviewed release in `modules/den/aspects/kubernetes/services/jellyfin.nix`,
   the expected release in `modules/tests/jellyfin-contracts.nix`, and stock
   image constants in `modules/tests/prod-home-replacement.py`. Selected
   source, patch and stock runtime metadata come from the same immutable
   release; changing an unselected producer must not change the running one.
5. Regenerate the manifests and run the checks:

   ```sh
   nix run .#sync-prod-home-manifests
   nix build .#checks."$system".jellyfin-contracts \
     .#checks."$system".prod-home-manifests-fresh
   nix build .#checks.x86_64-linux.prod-home-replacement \
     .#checks.x86_64-linux.prod-home-consumer-resilience
   ```

   Both runtime checks are required. Each uses an independent x86_64 Linux
   KVM fixture, a builder permitting `sandbox = relaxed`, and registry access.
6. Obtain separate consumer merge/rollout approval. Argo pulls the selected
   images; do not import helpers or activate the guest to deliver them.
7. After sync, accept hardware transcoding as described in "Accept hardware
   transcoding". A new release changes ffmpeg and the iHD driver.

Expected result: selected source, patch and stock runtime cannot drift
independently; changing an unselected producer leaves the selected release
unchanged. `jellyfin-contracts` and both runtime checks pass. Each runtime
fixture bootstraps the genuine Incus/ZFS/MergerFS/K3s/Argo stack from canonical
manifests, provisions Jellyfin, delivers staged secrets, and verifies the stock
image, administrator, libraries, and playback state.

The required runtime inventory is partitioned, not selected by changed files:

| Check | Mandatory scenario families |
| --- | --- |
| `prod-home-replacement` | Preseed adoption conflict; missing retained mount and permission drift; missing secrets and incomplete/complete rotation; bootstrap without Git and recovery; retained-marker/volume refusal; mapped retained-path owners and writes; lifecycle lock and identity/effective-config refusals; in-place OS activation; fresh Incus/K3s replacement retaining bytes, ownership, credentials and identity; accelerator grant after replacement; Argo retirement retaining Namespace/PV/PVC and data. |
| `prod-home-consumer-resilience` | Accelerator absence, hotplug, host/guest/workload permissions, ungranted/nonholder refusals, loss and return; Jellarr's declared-only encoding updates and key reuse; post-preflight provisioning failure, immutable partial state and kubelet refusal retries with the full 60-second observation; live media writer/read-only boundaries, mount loss/return without node restart, boot without media with the full 180-second observation, restoration; Argo self-healing retaining unmanaged objects and application data. |

Fixture Git availability and retirement request an Argo hard refresh instead
of waiting for its background polling interval. Argo still fetches the real
Git origin and performs reconciliation; all health, refusal, and retained
object assertions remain required.

### First real upgrade

Nobody has run this procedure yet. Jellyfin 12.1 was the first release
deployed, and the owner deferred the exercise to the next real upgrade (task
1.5 of the archived change `reproducible-jellyfin-compute`). At that upgrade,
record each item below in the upgrade pull request:

- [ ] The new `version`, `sourceRev`, `runtimeImage`, `runtimeDigest`, and
  `provisionPatchRev` all name the same upstream release, and they change in
  one reviewed change.
- [ ] `provision.patch` applies to the new source, or an upstream Provision
  mode replaced it and the patch is removed.
- [ ] On the upgrade branch, a temporary edit that changes only the server
  image or digest, or only the provisioner source, fails evaluation.
- [ ] Both `prod-home-replacement` and `prod-home-consumer-resilience` pass
  their complete required scenario inventories at the upgrade's head.
- [ ] After the Argo sync, the `provision` log on the production host reports
  that `/config` is initialized and left unchanged, the server reports the
  new version, and the administrator, libraries, and playback still work.
- [ ] Hardware transcoding is accepted on the production host with the new
  release.

When every item is recorded, remove this subsection.

## Provisioning failures

If the `provision` initContainer fails, the Pod stays in `Init:Error` or
`Init:CrashLoopBackOff` and the server does not start. Provisioning is not
transactional. A run that fails partway leaves `/config` partly written, and
nothing rolls it back. Every retry then refuses that state before it writes
anything:

```text
jellyfin-provision: refusing partial provisioning state in /config: ...
```

1. Find the original cause. The provisioner logs show the latest two runs;
   after several retries both may show only the refusal. Jellyfin's own log
   of the failed run stays in `log/` under the `jellyfin-config` host path.

   ```sh
   kubectl -n jellyfin logs deployment/jellyfin -c provision
   kubectl -n jellyfin logs deployment/jellyfin -c provision --previous
   ```

2. Fix the cause, for example a full volume or an out-of-memory kill.
3. Restore `/config` from a backup. If this is a first deployment with no
   state to keep, clear it instead (**destructive**): as root on the host,
   delete the contents of the `jellyfin-config` host path but keep the
   directory itself.

   ```sh
   sudo find <jellyfin-config host path> -mindepth 1 -delete
   ```

4. Delete the Pod to retry now instead of waiting for the back-off:

   ```sh
   kubectl -n jellyfin delete pod -l app.kubernetes.io/name=jellyfin
   ```

Expected result: the Pod becomes Ready, and the next `provision` log reports
one of these lines:

```text
jellyfin-provision: /config is empty; provisioning fresh state
jellyfin-provision: /config is initialized; Provision mode leaves it unchanged
```

Do not edit `system.xml` or the database to mark setup complete. That keeps
whatever partial accounts the failed run created.
