# Generates docs/operations/luks-storage-migration.md from the evaluated Den
# disk.luks-storage declarations. Regenerate with `nix run .#write-files`;
# `nix run .#diff-files` reports drift.
{
  config,
  lib,
  ...
}:
let
  hostDisks = lib.concatLists (
    lib.mapAttrsToList (
      _system: hosts:
      lib.concatLists (
        lib.mapAttrsToList (
          hostName: host:
          lib.mapAttrsToList (diskName: disk: {
            inherit hostName diskName disk;
          }) (host.settings.disk.luks-storage.disks or { })
        ) hosts
      )
    ) config.den.hosts
  );

  diskRows = map (
    entry:
    lib.concatStringsSep " | " [
      "| `${entry.hostName}`"
      "`${entry.diskName}`"
      "`prepare-luks-storage-${entry.diskName}`"
      "`${entry.disk.device}`"
      "`${entry.disk.mountpoint}`"
      "`${entry.disk.mapperName}`"
      "`${entry.disk.fsType}`"
      "${if entry.disk.provisioned then "yes" else "no"} |"
    ]
  ) hostDisks;

  diskTable =
    if hostDisks == [ ] then
      "No host declares a `disk.luks-storage` disk."
    else
      lib.concatStringsSep "\n" (
        [
          "| Host | Disk | Wrapper | Declared device | Mountpoint | Mapper | Filesystem | Provisioned |"
          "| --- | --- | --- | --- | --- | --- | --- | --- |"
        ]
        ++ diskRows
      );
in
{
  perSystem =
    { ... }:
    {
      files.file."docs/operations/luks-storage-migration.md".text = ''
        <!-- provenance: generated from evaluated Den/Nix declarations by modules/den/aspects/disk/luks-storage-docs.nix; keep the committed copy in sync. -->
        # LUKS2/XFS storage migration

        This procedure brings a declared data disk into service as a LUKS2
        container holding one XFS filesystem. It covers two cases:

        - **Format only:** a new or empty disk that receives no seed data.
        - **Seeded:** an empty disk that receives a verified copy of one
          direct source mount, such as an older disk that stays mounted and
          unchanged as the rollback copy.

        Every destructive step is a separate operator decision. This document
        describes tooling; it is not evidence that any physical step ran.

        ## Declared disks

        Each `disk.luks-storage.disks.<name>` declaration installs a wrapper
        named `prepare-luks-storage-<name>` on its host. The wrapper passes an
        immutable descriptor with the declared device, mapper, direct
        mountpoint, filesystem type, and agenix key path
        (`/run/agenix/luks-<name>-key`).

        ${diskTable}

        `Provisioned = no` means the host has only the agenix key. `yes` adds
        the crypttab row and the direct mount. Neither value proves that
        physical work ran.

        ## Safety model

        Do not pass a device, mapper, or key path to the generic
        `prepare-luks-storage` package; use the per-disk wrapper. Run
        `prepare-luks-storage-<name> describe` to print the descriptor.

        The tool has these operations:

        1. `preflight` is read-only. It resolves the declared whole disk,
           binds its by-id path, serial, WWN, and byte size, and inspects all
           children, mounts, holders, and whole-disk signatures. With
           `--source`, it also inspects the direct source mount, measures
           apparent and allocated source bytes, and checks that the raw target
           capacity covers the source plus 10 GiB headroom. Without
           `--source`, the evidence records `SOURCE=none`.
        2. `format` requires the exact target confirmation and preflight
           evidence. It rechecks the target (and the source, if the evidence
           records one), requires the declared root-private agenix key, and
           repeats the target probes immediately before `sgdisk`. It only
           partitions the evaluated target and runs `cryptsetup luksFormat`.
        3. `quiesce` requires evidence with a direct source. It rechecks the
           destination and the source's filesystem identity against that
           evidence, then records a fresh source token once, after
           `--writers-stopped` or `--independent-consistency` is asserted.
        4. `copy` requires evidence with a direct source, a quiescence record
           from `quiesce` (or a version 1 record bound to the preflight
           token), a direct XFS destination mount, and `--approve-copy`. It
           copies the source into a new `.seed` tree at the destination root,
           then verifies it.
        5. `normalize` reshapes the verified staging tree into the target
           layout with same-filesystem renames only, after
           `--approve-normalize`. It never copies data.

        Evidence is bound to the descriptor and rechecked; it is not a
        free-form confirmation string. Any missing, conflicting, changed, or
        failed probe is `MANUAL` or a failed gate, and neither permits a
        mutator. If the target has a child, mount, holder, partition-table
        signature, filesystem signature, or an uncertain probe, stop. Do not
        use `wipefs -a` to make a gate pass. Never use a pooled (mergerfs)
        namespace as either copy endpoint.

        ## 1. Seeded disks: stop writers and fix the source

        Skip this step for a format-only disk.

        Use the actual host workload inventory. Pause automated
        reconciliation for every application that can write to the source,
        then stop or suspend every writer. Scaling one deployment is not a
        quiescence proof. Record the prior state for restoration.

        The source must be a canonical, direct mount, not a pooled namespace:

        ```sh
        set -eu
        DISK=NAME                          # the Den disk name
        SOURCE=/mnt/storage-clear/SOURCE   # the direct source mount
        EVIDENCE=/run/$DISK-preflight
        QUIESCENCE=/run/$DISK-quiescence
        RECEIPT=/run/$DISK-copy-receipt

        test "$(realpath -e -- "$SOURCE")" = "$SOURCE"
        test "$(findmnt -rn -T "$SOURCE" -o TARGET)" = "$SOURCE"
        test "$(findmnt -rn -T "$SOURCE" -o FSTYPE)" != fuse.mergerfs
        ```

        Inspect all writers again after they stop. If writers cannot be
        stopped, obtain independent application-consistency evidence instead;
        an operator assertion alone is not that evidence.

        Keep evidence files off both the source and the destination mount;
        the tool refuses evidence paths below either one.

        ## 2. Read-only preflight

        Seeded disk:

        ```sh
        prepare-luks-storage-$DISK preflight --source "$SOURCE" --evidence "$EVIDENCE"
        ```

        Format-only disk:

        ```sh
        prepare-luks-storage-$DISK preflight --evidence "$EVIDENCE"
        ```

        Continue only when the command exits zero and prints:

        ```text
        READ_ONLY_INVENTORY=PASS
        FORMAT_TARGET_CLEAR=PASS
        FORMAT_READINESS=PASS
        FORMAT_TARGET_CONFIRMATION=...
        PREFLIGHT_EVIDENCE=...
        ```

        Record the complete output without key material. The evidence file
        holds the descriptor digest, the target identity, and either
        `SOURCE=none` or the source mount, device, filesystem type, UUID,
        device number, byte counts, provenance token, and the capacity
        calculation. Review these facts against the host before approving
        format.

        The target-clear gate requires:

        - no partition or device-mapper child;
        - no target or child mount;
        - no holder;
        - a successful whole-disk `wipefs -n --output TYPE` probe;
        - no partition-table signature and no filesystem or LUKS signature;
        - a stable WWN by-id alias and readable serial, WWN, and byte size.

        With a source, the source gate also requires a canonical real
        directory mounted exactly at `$SOURCE`, no nested mount, no pooled
        source, successful device-number and byte measurements, and enough
        raw target capacity.

        The evidence is valid only for this descriptor and, when present,
        this source snapshot. Do not hand-edit it or reuse it after any
        identity or source change. `SOURCE=none` evidence can authorize
        format but never a copy; to seed such a disk, run a new preflight with
        `--source` before formatting.

        ## 3. Separately approve LUKS2/XFS realization

        Approve format only after recovery passphrase escrow, protected
        header-backup storage, and the runtime agenix key path are ready.
        Never put a passphrase or key in a command, shell history, evidence
        file, or review artifact:

        ```sh
        TARGET_CONFIRMATION=$(sed -n 's/^TARGET_TOKEN=//p' "$EVIDENCE")
        test -n "$TARGET_CONFIRMATION"
        prepare-luks-storage-$DISK format \
          --evidence "$EVIDENCE" \
          --confirm-target "$TARGET_CONFIRMATION" \
          --approve-format
        ```

        No `sgdisk` command is reachable if any recheck fails. A partial
        `sgdisk` failure is a new recovery operation, not a reason to rerun
        ordinary preflight.

        Take the partition, mapper, and key path from `describe` and the
        format output, then create the filesystem and add the agenix keyslot:

        ```sh
        prepare-luks-storage-$DISK describe
        PARTITION=...   # DECLARED_DEVICE from describe
        MAPPER=...      # MAPPER from describe
        KEY_FILE=...    # KEY_FILE from describe

        cryptsetup open "$PARTITION" "$MAPPER"
        if blkid "/dev/mapper/$MAPPER"; then
          echo "unexpected filesystem on newly formatted mapper" >&2
          cryptsetup close "$MAPPER"
          exit 1
        fi
        mkfs.xfs "/dev/mapper/$MAPPER"
        cryptsetup close "$MAPPER"
        cryptsetup luksAddKey "$PARTITION" "$KEY_FILE"
        ```

        Test both unlock paths with a close and reopen cycle: the recovery
        passphrase interactively, then `cryptsetup open --key-file
        "$KEY_FILE"`. After the final keyslot change, create and protect the
        off-host header backup:

        ```sh
        HEADER=/protected/off-host/$DISK-luks-header.img
        cryptsetup luksHeaderBackup "$PARTITION" --header-backup-file "$HEADER"
        sha256sum "$HEADER"
        cryptsetup luksDump --header "$HEADER" "$PARTITION"
        ```

        Verify a copied header in a disposable recovery fixture. Record the
        header hash, LUKS UUID, filesystem UUID, and keyslot roles, never the
        keys.

        ## 4. Mount the disk directly

        Formatting, key and header recovery, and mounting are separate
        approvals. In a host revision, change only the disk declaration to
        `provisioned = true`. Do not add the disk to any pool yet.

        After activation, verify the crypttab row, mapper, LUKS UUID, XFS
        UUID, direct mount source and type, and device number:

        ```sh
        MOUNTPOINT=...  # MOUNTPOINT from describe
        findmnt -rn -T "$MOUNTPOINT" -o TARGET,SOURCE,FSTYPE,UUID
        cryptsetup status "$MAPPER"
        stat -c '%d' -- "$MOUNTPOINT"
        ```

        The mount must be the exact direct XFS mount with no nested mount.

        ## 5. Seeded disks: record quiescence and copy

        Writers and reconciliation must stay stopped from the source
        inventory through copy verification, normalization, any pool change,
        and acceptance.

        A host activation can restart a FUSE source, which then remounts with
        a new anonymous device number and filesystem UUID. Do not hand-write
        a token from preflight evidence; run `quiesce`. It rechecks the
        destination, requires the same filesystem identity (mount path, mount
        source, filesystem type) as preflight, records a fresh source token,
        and reports the fields that drifted:

        ```sh
        prepare-luks-storage-$DISK quiesce \
          --evidence "$EVIDENCE" \
          --quiescence-evidence "$QUIESCENCE" \
          --writers-stopped
        ```

        Run it only after the recorded workload inventory proves that all
        writers are stopped; `--writers-stopped` is that operator assertion.
        If writers cannot be stopped, use `--independent-consistency` only
        when independently reviewed evidence establishes a stable source
        snapshot. `quiesce` refuses if the quiescence file already exists;
        delete it deliberately to re-stabilize.

        The copy command rechecks the evidence, target identity, direct XFS
        mount, free space, and source provenance, and requires the source to
        be unchanged since quiescence. It refuses a non-empty destination or
        an existing staging tree. Approve the write separately:

        ```sh
        prepare-luks-storage-$DISK copy \
          --evidence "$EVIDENCE" \
          --quiescence-evidence "$QUIESCENCE" \
          --receipt "$RECEIPT" \
          --approve-copy
        ```

        The command copies `$SOURCE/` to `$MOUNTPOINT/.seed/` with sparse
        files, ACLs, xattrs, numeric IDs, hardlinks, and metadata preserved.
        It never deletes destination entries, writes to the source, or formats
        a partition. It then requires:

        - rsync checksum and itemized verification with no changes or errors;
        - exact relative entry, type, and symlink comparison;
        - matching hardlink peer groups;
        - no sparse source file expanded into a fully allocated destination.

        Only a `COPY_VERIFIED=PASS` receipt is sufficient to continue. The
        receipt records the staging root as `SEED_ROOT`. On any copy or
        verification failure, leave the staging tree for inspection, keep the
        source untouched, and do not retry with `--delete`.

        ## 6. Seeded disks: normalize the staged tree without a second copy

        The staging tree is a complete copy of the source root. `normalize`
        reshapes it with same-filesystem renames. Select the layout profile
        that names the shape of the source tree; the tool refuses unknown
        profiles. The known profile is:

        `legacy-medialibrary`: the source root holds exactly one
        `medialibrary/` directory with five children.

        | Staged path (`SEED_ROOT/`) | Final path (`$MOUNTPOINT/`) |
        | --- | --- |
        | `medialibrary/movies` | `library/movies` |
        | `medialibrary/tv` | `library/tv` |
        | `medialibrary/downloads` | `downloads` |
        | `medialibrary/dewey-incoming` | `legacy/dewey-incoming` |
        | `medialibrary/staging` | `legacy/staging` |

        After the copy receipt passes, run:

        ```sh
        prepare-luks-storage-$DISK normalize \
          --evidence "$EVIDENCE" \
          --receipt "$RECEIPT" \
          --layout legacy-medialibrary \
          --approve-normalize
        ```

        Before it changes anything, the command:

        - rechecks the preflight target identity and reports each drifted
          field, and refuses `SOURCE=none` evidence;
        - requires the exact direct XFS mount with no nested mount;
        - reads the copy receipt strictly (unknown or duplicate fields fail)
          and requires `COPY_VERIFIED=PASS`. A version 2 receipt must carry
          the SHA-256 of this evidence file and descriptor. A version 1
          receipt, written before receipts carried digests, must record this
          evidence's source path, the descriptor mountpoint, and the mounted
          filesystem UUID. A changed device number is reported, not fatal,
          because a dm-crypt mapping can get a new number after a reboot;
        - takes the staging root from the receipt's `SEED_ROOT`, which must
          be a direct child of the descriptor mountpoint. Copies made before
          staging moved to `.seed` recorded a different name there;
        - requires the mountpoint to contain only the staging root, and the
          staging root to match the selected profile exactly. Each entry must
          be a real directory (not a symlink) on the destination filesystem.
          Any other layout fails with a listing of what was found; it does not
          guess a mapping.

        It then creates the profile's new directories (mode 0755, owned by
        root), renames each entry with `mv -T --no-copy --update=none-fail`,
        and removes the emptied directories and the staging root with
        `rmdir`. `--no-copy` makes a cross-filesystem rename fail instead of
        falling back to copy and delete; `--update=none-fail` refuses to
        replace an existing path. Renames keep ownership, modes, content,
        hardlinks, and sparse extents, so the copy receipt remains the content
        proof.

        On success it prints the final layout and writes `$RECEIPT.normalized`
        (mode 0600) with `NORMALIZED=PASS`, the layout, the staging root, and
        the resulting root, `library/`, and `legacy/` entries.

        A second run refuses: the normalize receipt exists and the root no
        longer holds only the staging root. If a run stops partway, the
        command refuses without changes and lists the root entries. Inspect
        and finish the renames by hand; do not copy.

        ## 7. Put the disk into service

        A later, separately approved host revision adds the direct mount to
        its consumer, for example as a mergerfs branch that depends on the
        disk's mount unit. When the disk replaces a source branch, change the
        branch set in one activation; do not run with both the source and the
        new disk as branches, and do not reload the pool ad hoc.

        Reassert both direct mounts immediately before that activation. Then
        inspect the running pool and prove that the branch set is exactly the
        declared one.

        Do not unmount, delete, repartition, or re-encrypt the source. It
        stays the intact rollback copy. If acceptance fails, use a separately
        approved branch-only rollback revision. After writers resume, the
        source is historical rather than a lossless rollback; reconciling
        later changes back to it needs its own approval.

        ## 8. Acceptance and restoration

        Recreate every consumer that binds a subtree of the changed namespace
        while writers remain stopped. Verify that readers see the expected
        tree, writers can create, hardlink, and rename within one filesystem,
        and no checksum, UUID, branch, or readiness error remains.

        Then restore each recorded reconciliation policy and writer state, and
        verify that writers resumed against the new disk. Formatting the old
        source disk later is a separate operation with its own preflight and
        explicit destructive approval.

        ## Operator gates outside the repository

        1. The authorized host is available and the operator can inspect the
           declared by-id device.
        2. Recovery passphrase escrow, agenix key delivery, and protected
           header backup and recovery evidence are complete.
        3. Preflight output and evidence are reviewed against the physical
           target and, for a seeded disk, the direct source.
        4. Format, the direct-mount revision, copy, normalization, and the
           pool revision are separate decisions.
        5. Quiescence or independent consistency evidence stays valid through
           the copy and cutover.
        6. Consumer refresh and acceptance pass before writers and
           reconciliation resume.
      '';
    };
}
