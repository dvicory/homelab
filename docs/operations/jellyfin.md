# Jellyfin operations

Jellyfin runs in the `jellyfin` namespace on the compute guest. Before the
server starts, the `provision` initContainer prepares retained state. The
`jellyfin-configuration` Job then applies the declared libraries and
settings.

In the commands below, set `system` to the host system and `instance` to the
compute guest listed under "Current stack" in
[`docs/operations.md`](../operations.md).

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
2. Update the guest with the new bundle (`compute-guest replace`, in
   [`docs/operations.md`](../operations.md)). The bundle creates `/dev/dri`
   at boot and carries the new `retained-directories` image. If you defer
   the replacement, import that image into the guest as in "Deliver helper
   images" before merging. Until the replacement, a guest that restarts
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

Kubernetes never pulls the provisioner and Jellarr images. Import each new
revision into the guest before you sync manifests that reference it. Do not
rebuild or activate the guest OS for this.

1. On the Linux Incus host, from the selected repository revision, build the
   images in Bash:

   ```sh
   archives=$(nix build --no-link --print-out-paths \
     .#packages."$system".jellyfin-provisioner-image \
     .#packages."$system".jellarr-image) || exit 1
   ```

2. Import each archive into the existing guest. The command forwards stdin on
   purpose:

   ```sh
   while IFS= read -r archive; do
     sudo incus --project compute exec "$instance" -- \
       k3s ctr --namespace k8s.io images import - < "$archive" || exit 1
   done <<< "$archives"
   ```

3. Before the Argo sync, confirm that containerd lists every `homelab/`
   image the manifests declare:

   ```sh
   grep -rhoE 'homelab/[a-z-]+:[a-z0-9]+' \
     generated/manifests/prod-home/jellyfin \
     generated/manifests/prod-home/jellyfin-configuration | sort -u
   sudo incus --project compute exec "$instance" -- \
     k3s ctr --namespace k8s.io images ls -q
   ```

## Upgrade Jellyfin

The provisioner and the server must run the same Jellyfin release. Change
them together in one reviewed change:

1. In `pkgs/by-name/jellyfin-provisioner-image/package.nix`, set `version`,
   `sourceRev` and its source hash, `runtimeImage`, and the
   architecture-specific `runtimeDigest` for the same upstream release.
   `version` also selects the nixpkgs-multiverse Jellyfin build.
2. Confirm that `provision.patch` still applies, and update it and
   `provisionPatchRev` together. When upstream ships an equivalent Provision
   mode, remove the patch and keep the initContainer and the stock server as
   they are.
3. Make the same release change in the reviewed release in
   `modules/den/aspects/kubernetes/services/jellyfin.nix`, the expected
   release in `modules/tests/jellyfin-contracts.nix`, and the stock image
   constants in `modules/tests/prod-home-replacement.py`.
4. Regenerate the manifests and run the checks:

   ```sh
   nix run .#sync-prod-home-manifests
   nix build .#checks."$system".jellyfin-contracts \
     .#checks."$system".prod-home-manifests-fresh
   nix build .#checks.x86_64-linux.prod-home-replacement
   ```

   `prod-home-replacement` needs x86_64 Linux with KVM, a builder that
   permits `sandbox = relaxed`, and registry access.
5. After merge, deliver the new provisioner image as described above before
   the Argo sync.
6. After the sync, accept hardware transcoding as described in "Accept
   hardware transcoding". A new release changes ffmpeg and the iHD driver.

Expected result: evaluation fails if only the server image or digest, or only
the provisioner source, changes. `jellyfin-contracts` passes and
`prod-home-replacement` passes fresh provisioning, repeat provisioning after
Pod recreation, the stock-server image check, Jellarr key reuse, and the
provisioning-failure scenario.

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
- [ ] `prod-home-replacement` passes fresh provisioning, repeat provisioning,
  and the stock-server image check at the upgrade's head.
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
