# Household software cutover

Status: preparation only. Production deployment is not authorized. No
successful `prod-home-replacement` acceptance or measured healthy runtime is
recorded here; complete the current acceptance before scheduling this cutover.
The repository desired state for this cutover keeps media1–media3 on their
existing gocryptfs providers. That is transitional until the software cutover
is proven, not the target LUKS2/XFS bulk-media state. This procedure does not
provision media4, convert filesystems, or migrate media ownership.

## Release gate

- Select one immutable revision with current generated manifests and passing
  checks. This is a gate for a future run, not a current acceptance result.
  Record the Linux replacement run URL, actual duration, phase timings, and
  media-return observations. A successful evaluation or a cached `.drv` file
  is not an executed acceptance test.
- Review [generated operations](../operations.md) for current paths, routes,
  retained-state ownership and secret references. Review the canonical manifest
  diff before merging: `main` is the production Argo desired-state branch.
- Obtain explicit approval for production inspection, credentials, host
  activation, Incus interruption and any guest replacement. Inspect first;
  do not assume production matches this checkout or that retained paths are empty.
- Confirm an independently recoverable copy of valuable application state and
  the required keys. Host-local retained directories are not a backup. Stop if
  existing data requires an unapproved ownership or layout migration.
- Keep the previous host system, guest bundle and source revision available.
  Record which applications would need data restoration rather than merely
  an older binary after a failed cutover.

On an x86_64 Linux/KVM builder, the online acceptance command is:

```sh
nix build -L --no-link --option sandbox relaxed .#checks.x86_64-linux.prod-home-replacement
```

The test explicitly opts out of the build sandbox for public registry pulls.
Its guest egress setting alone does not grant the builder network access.

To run only this acceptance on GitHub's x86_64 runner, select a branch or tag
containing the revision to verify:

```sh
gh workflow run ci.yml --repo dvicory/homelab --ref "$REF" -f target=replacement
```

This diagnostic selection does not replace the full release checks. The test
verifies its serial output channel before starting, then streams phase markers
and bootstrap output. Kernel activity alone does not establish progress or pass.
While bootstrap waits, bounded read-only snapshots show Argo pods/events, the
Redis-init Job log, and active image downloads. Bootstrap has a one-hour
process-group deadline with a 30-second forced-kill grace.

## Host preparation and activation

1. Inspect the actual storage mounts and Incus inventory. Confirm encrypted
   backing mounts, gocryptfs branches, `/srv/media`, retained state, and the
   declared capability mapping. Do not recursively chown media or retained data.
2. Stage the declared secrets through agenix/rekey. Verify availability without
   printing values. Retain the existing guest SSH identity; do not regenerate it
   to resolve a mismatch. Keep the legacy Hermes nspawn integration and its secret.
3. Build the selected host system and `compute-1` bundle. Deploy the host through
   the existing approved deployment path. Review activation/restart effects;
   changes to Incus subordinate-ID authorization require an Incus restart and
   may interrupt every Incus guest, not just `compute-1`.
4. Verify gocryptfs units depend on the real escaped backing `.mount` units,
   absent branch mountpoints are root-owned mode `0000`, and mergerfs refuses
   missing providers. If the selected revision changes the branch set, apply
   that change through a controlled mergerfs service restart after all intended
   providers are mounted; do not use a live branch reload. Verify host-private
   management remains reachable.
5. Inspect `/etc/homelab/compute.json` with the shipped `compute-guest inspect`.
   A preseed, identity, mount or effective-map mismatch is a stop condition, not
   permission to bypass a guard or hand-edit the instance into agreement.

## Guest and GitOps cutover

1. Use `compute-guest create --bundle BUNDLE` only for an absent guest. For an
   existing guest, obtain explicit destructive approval before using
   `compute-guest replace --bundle BUNDLE --confirm compute-1`. Preserve the
   designated host-owned state and identity throughout.
2. Run the shipped host bootstrap:

   ```sh
   household-bootstrap-host /etc/homelab/compute.json --confirm compute-1
   ```

   It obtains fresh Kubernetes credentials, applies staged secrets and the Argo
   seed, then hands off the root Application. Do not restore the old K3s database
   or replace this path with manual application manifests.
3. Verify Argo's root and child applications reconcile the approved `main`
   revision. Seed readiness alone does not establish application readiness.
4. Check native application authentication and retained user/library/playback
   state. Verify the capability map, writable acquisition paths, Jellyfin's
   read-only `/media` mount, and private endpoint denials. Test the intended
   ingress/TLS/client paths separately; the replacement fixture does not prove
   production DNS, certificates, GPU transcoding or every household application.
5. Apply the measured media-restoration procedure. Do not assume existing pod
   bind mounts follow a remounted source; restart affected pods if the acceptance
   observation establishes that requirement. Unrelated workloads must remain up.

## Stop and rollback

On a failed gate, retain logs and durable state; stop further mutation. Restore
the previous host generation only after checking its storage/map compatibility.
Guest rollback uses an approved bundle and the same retained-data prerequisites.
Neither an OS rollback nor Argo reconciliation undoes database migrations, file
ownership changes, deleted data, or an already formatted disk.

The [media4-first conversion](media4-conversion.md) is a later, separately
approved operation. Do not combine it with this software cutover.
