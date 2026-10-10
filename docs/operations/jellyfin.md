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
- `/cache` is disposable, up to 4 GiB, and is deleted with the Pod.

## Before deployment

1. Encrypt and rekey a strong, unique password for the declared Jellyfin
   administrator as `jellyfin--jellyfin-admin--password` for the compute
   guest.
2. When you restore initialized `/config`, use that state's existing
   administrator password. The secret does not reset it.

The administrator name may use ASCII letters, digits, spaces (not leading or
trailing), and `_ . ' @ + -`. Evaluation rejects other names. If the password
secret is missing, provisioning fails and Jellyfin does not start.

## Add media to an existing guest

Do this once, before the merge that deploys Jellyfin, on a guest created
without the `media` storage capability. A guest created with it skips this
section.

The capability changes the guest's group ID map so that the host's media
group keeps its ID inside the guest. Incus applies the project's ID-map
restriction before the profile's map and checks each against the other, so
the old and new values block each other. Host activation therefore leaves
Incus unchanged until you bridge them, and the new map applies only when the
guest restarts. The restart keeps the guest's root filesystem, K3s data and
retained state.

Run these steps in Bash on the Incus host. `jq` runs as your user; `sudo`
runs only the Incus and systemd commands.

1. Check the guest before activation:

   ```sh
   spec=/etc/homelab/compute.json
   project=$(jq -r .project "$spec") instance=$(jq -r .instance "$spec")
   sudo compute-guest inspect >/dev/null && echo inspect-ok
   sudo incus --project "$project" config get "$instance" volatile.last_state.idmap
   ```

   Expect `inspect-ok` and `[]`. `[]` means the root filesystem uses
   idmapped mounts, so the restart does not rewrite file ownership. If it
   prints a map instead, stop: the restart would rewrite ownership across the
   whole root filesystem.
2. Activate the host revision with `switch-to-configuration test`. Expect
   exit status 4 with only `incus-preseed.service` failed, and
   `journalctl -u incus-preseed -n 5 -o cat` shows
   `Conflict detected … raw.idmap … is forbidden`. The guest keeps running.
3. Under the guest's lifecycle lock, permit both maps for one step and move
   the profile to the declared map:

   ```sh
   spec=/etc/homelab/compute.json
   project=$(jq -r .project "$spec") instance=$(jq -r .instance "$spec")
   profile=$(jq -r .profile "$spec") map=$(jq -r '.config."raw.idmap"' "$spec")
   gids=$(jq -r '[.capabilityGids[] | tostring]
     + ["\(.idmapBase)-\(.idmapBase + .idmapSize - 1)"] | join(",")' "$spec")
   sudo flock -n "/run/lock/compute-$project-$instance.lock" sh -ec \
     'incus project set "$1" restricted.idmap.gid="$2"
      incus --project "$1" profile set "$3" raw.idmap="$4"' \
     sh "$project" "$gids" "$profile" "$map"
   ```

4. Reapply the declaration. The preseed narrows the project's restriction
   back to the declared value:

   ```sh
   sudo systemctl restart incus-preseed.service
   systemctl --failed
   ```

   Expect no failed units. `compute-guest inspect` still refuses the guest
   with `incompatible effective ID map` until the restart.
5. Restart the guest. In testing the Kubernetes API was unavailable for
   under 30 seconds; workloads take longer to become Ready:

   ```sh
   sudo flock -n "/run/lock/compute-$project-$instance.lock" \
     incus --project "$project" restart "$instance" --timeout=120
   ```

6. Confirm the result, then stage runtime secrets again:

   ```sh
   sudo compute-guest inspect >/dev/null && echo inspect-ok
   sudo incus --project "$project" exec "$instance" -- cat /proc/self/gid_map
   sudo incus --project "$project" exec "$instance" --user 751 --group 505 -- \
     ls /srv/media/data/library
   sudo incus --project "$project" exec "$instance" -- k3s kubectl get nodes
   sudo systemctl restart compute-stage-secrets.service
   ```

   Expect `inspect-ok`, a `gid_map` row mapping 505 to 505, the library
   listing, and the node `Ready`.
7. Deliver the helper images below, then merge.

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

Expected result: evaluation fails if only the server image or digest, or only
the provisioner source, changes. `jellyfin-contracts` passes and
`prod-home-replacement` passes fresh provisioning, repeat provisioning after
Pod recreation, the stock-server image check, Jellarr key reuse, and the
provisioning-failure scenario.

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
