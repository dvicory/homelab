# Household software cutover

Status: preparation only. The disposable x86_64/KVM recovery acceptance passed;
production inspection and deployment remain separately authorized. The result
below does not establish that `hvn-hyp1` is ready for this cutover.
The repository desired state for this cutover keeps media1–media3 on their
existing gocryptfs providers. That is transitional until the software cutover
is proven, not the target LUKS2/XFS bulk-media state. This procedure does not
provision media4, convert filesystems, or migrate media ownership.

## Release gate

- Select one immutable revision with current generated manifests and passing
  checks. Record the Linux replacement run URL, actual duration, phase timings, and
  media-return observations. The recorded acceptance covers its named revision,
  not future changes. A successful evaluation or a cached `.drv` file is not
  an executed acceptance test.
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
gh workflow run ci.yml --repo dvicory/homelab --ref "$REF" -f check=prod-home-replacement
```

This diagnostic selection does not replace the full release checks. The test
verifies its serial output channel before starting, then streams phase markers
and bootstrap output. Kernel activity alone does not establish progress or pass.
While bootstrap waits, bounded read-only snapshots show Argo pods/events, the
Redis-init Job log, and active image downloads. Bootstrap has a one-hour
process-group deadline with a 30-second forced-kill grace.

### Recorded recovery acceptance

[Run 34827468677](https://github.com/dvicory/homelab/actions/runs/34827468677)
passed on 2026-09-14 at revision
`dfda4c03c12f1b0492cb65fee26f4af0267dcfae`. The x86_64/KVM job executed
`/nix/store/6ijlwnkj1ihvakhq8cnxkcl8ga1bizy1-vm-test-run-prod-home-replacement.drv`.

| Observed interval | Duration |
| --- | --- |
| Entire CI job | 35m53s |
| Build-step preparation before the VM derivation started | 14m27s |
| Fixture VM startup | 93.16s |
| Subsequent wait for fixture Incus | 18.07s |
| Complete replacement scenario, including cleanup | 1127.58s |
| Initial guest creation and K3s readiness | 117.87s |
| First bootstrap, registry pulls, and Argo reconciliation | 148.86s |
| Media loss and return | 37.33s |
| Guest replacement and K3s readiness | 165.26s |
| Second bootstrap, registry pulls, and Argo reconciliation | 144.95s |

The bootstrap command itself took 68.81s initially and 65.71s after replacement;
those intervals are included in the corresponding reconciliation phases.
Guest root and K3s state were recreated. Authentication, indexed media, recorded
playback, retained bytes/ownership, credential inputs, unrelated workload
availability, private endpoint denials, and Jellyfin's read-only mount passed.

Existing Jellyfin and writer-probe containers did not see the remounted media.
A fresh Jellyfin pod read it without restarting the node. A separate reboot
without media kept Jellyfin unavailable throughout the 180-second observation
while CoreDNS answered live probes. Argo self-healing also preserved application
state; test access was re-established after replacing its target pod.

This uses file-backed ZFS, temporary media branches, disposable credentials,
and a local Git origin containing canonical Jellyfin manifests. It does not
prove physical storage unlock, gocryptfs startup, production DNS/TLS/ingress,
GPU support, every household application, or recovery from host loss.

## Fast runtime checks

Run deterministic lifecycle and bootstrap checks without booting a VM:

```sh
nix build -L --no-link .#compute-runtime
```

The package runs all applicable Go tests, including internal packages. For
quicker iteration with a warm Go cache and no C compiler requirement:

```sh
nix shell --inputs-from . nixpkgs#go --command \
  env CGO_ENABLED=0 go -C pkgs/by-name/compute-runtime test ./...
```

The existing CI selector can run only these Go package checks:

```sh
gh workflow run ci.yml --repo dvicory/homelab --ref "$REF" \
  -f check=compute-runtime -f system=x86_64-linux
```

Go tests cover ID-map validation, readiness decisions, hook retry eligibility,
and Incus operation outcomes and deadlines. Linux-only guards run on Linux.
Keep the full replacement acceptance for kernel isolation, mount propagation,
media loss and recovery, and retained application state after guest destruction.

## Focused storage check

For a storage-only CI run, select a revision containing the desired manifests
and check:

```sh
gh workflow run ci.yml --repo dvicory/homelab --ref "$REF" -f check=compute-storage-zfs
```

This dispatch runs exactly one check,
`checks.x86_64-linux.compute-storage-zfs`. The equivalent local build on an
x86_64 Linux/KVM builder is:

```sh
nix build -L --no-link --option sandbox relaxed .#checks.x86_64-linux.compute-storage-zfs
```

The focused check is a disposable x86 NixOS/ZFS/Jellyfin storage test using
the production-declared kernel 6.18.49, ZFS 2.4.4, a real ZFS-backed Incus
pool, and pinned Jellyfin manifests. Native observations are diagnostic;
overlayfs must show real Jellyfin `Healthy` responses under the unchanged 1Gi
limit. Successful check jobs upload their Nix outputs as
`check-output-x86_64-linux-<run-id>`; build logs, including failures, remain in the
Actions job logs. This is not the full `prod-home-replacement` acceptance, does
not make an Argo or recovery claim, and changes no production system.

The workflow builds the selected Nix check directly, using durable/upstream caches
instead of Hestia's RAM-heavy path for check jobs. Set `-f system=aarch64-linux`
to exercise the same scenario on a native ARM fixture. Without KVM it uses
software emulation; that is portability coverage, not production validation.

The repository's selected-actions allowlist must permit the exact
`actions/upload-artifact` commit pinned in the workflow. Updating that pin
also requires updating the allowlist; retain the SHA-pinning requirement.

## Host preparation and activation

1. Inspect the actual storage mounts and Incus inventory. Confirm encrypted
   backing mounts, gocryptfs branches, `/srv/media/data`, retained state, and the
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
5. After restoring the pool at `/srv/media/data`, recreate affected media pods
   to refresh their subtree binds. Incus must retain its recursive `rslave`
   attachment of the stable `/srv/media` parent; binding the pool root directly
   cannot follow its replacement. Keep the compute guest and unrelated workloads up.

## Stop and rollback

On a failed gate, retain logs and durable state; stop further mutation. Restore
the previous host generation only after checking its storage/map compatibility.
Guest rollback uses an approved bundle and the same retained-data prerequisites.
Neither an OS rollback nor Argo reconciliation undoes database migrations, file
ownership changes, deleted data, or an already formatted disk.

The [media4-first conversion](media4-conversion.md) is a later, separately
approved operation. Do not combine it with this software cutover.
