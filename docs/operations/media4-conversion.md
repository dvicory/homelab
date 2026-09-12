# Planned media4-first LUKS2/XFS conversion

Status: follow-up outline, not an executable or authorized migration. No
physical conversion or successful media acceptance has been performed. First
complete the [software cutover](software-cutover.md) with the existing
gocryptfs media1–media3 providers. This operation is separate and does not
prepare or prove that cutover.

## Required repository changes before provisioning

- In repository desired state, media4 remains unprovisioned with a Btrfs
  declaration. Before physical provisioning, change only media4's future
  filesystem declaration and provisioning help to XFS above LUKS2. Keep the
  current media1–media3 gocryptfs backing filesystems unchanged; do not turn
  this into a fleet-wide XFS rule. The current provisioner package does not
  include `xfsprogs`/`mkfs.xfs`, so the provisioning environment must supply
  it.
- Remove the unconditional `discard` from `disk.luks-storage` crypttab output
  for these HDDs. The minimum change is `luks`; SSD discard policy can be
  explicit if needed later.
- Select a provider-neutral backing mount name, for example
  `/mnt/storage/media4`, below the stable `/srv/media` interface. Coordinate
  converted branch names in the later migration; do not rename the live
  gocryptfs branches during software acceptance.
- Harden `prepare-luks-storage` before trusting it with disks. It currently
  checks for a block device, absence of `-part1`, and typed serial confirmation,
  then wipes the partition table and runs `luksFormat`. It does not reject every
  other partition, mounted child, holder or non-whole-disk target. Require an
  idle whole disk, verify the device identity and required key material before
  destructive commands, and remove advice to bypass refusal with `wipefs`.
- Complete the recovery procedure below. The current provisioner does not
  create a filesystem, verify both unlock methods, or escrow a LUKS header;
  it only prints a manual recipe after formatting.

Relevant sources: [LUKS aspect](../../modules/den/aspects/disk/luks-storage.nix),
[host declaration](../../modules/den/hosts/hvn-hyp1/default.nix), and
[provisioner](../../pkgs/by-name/prepare-luks-storage/prepare-luks-storage.sh).
In repository desired state, media4 remains `provisioned = false` and is not an
active mergerfs branch.

## Provisioning and recovery gate

1. Obtain explicit destructive approval. Reconfirm the spare disk by WWN,
   model, size and physical serial—not a transient `/dev/sdX` name. Check actual
   capacity, mounts, partitions and holders. The committed hardware inventory
   alone is insufficient.
2. With `provisioned = false`, generate/rekey and deploy the existing agenix key
   through the approved flow. Verify the runtime key is readable without
   printing it. Escrow the independent recovery passphrase and key material
   outside the host before relying on them.
3. Use the hardened provisioner for LUKS2, open the new container, and create XFS
   with the agreed stable label. Add the agenix keyslot. Test both the operator
   recovery passphrase and the agenix key with a close/reopen cycle.
4. After the final keyslot change, run `cryptsetup luksHeaderBackup` to a
   protected destination and escrow a verified copy off-host. Record the disk
   WWN, partition identity, LUKS UUID, mapper, filesystem UUID/label and keyslot
   roles without recording plaintext keys. A header backup is sensitive: old
   headers can preserve access through previously valid keys.
5. Set `provisioned = true`, deploy, and verify the declared mapper and XFS
   mount. Test the recovery instructions against the new empty disk. Do not
   expose it through mergerfs until these checks pass.

## Leapfrog one branch at a time

1. Confirm a selected source branch fits on the empty destination, including
   metadata and working headroom. Decide the independent protection for data
   that must survive operator error or host loss.
2. Copy from the decrypted branch directly to the new XFS branch, preserving
   hardlinks, numeric ownership, permissions, ACLs and xattrs. A tool such as
   `rsync -aHAX --numeric-ids` is appropriate; do not copy through the pooled
   namespace or silently rewrite IDs during encryption conversion.
3. Quiesce all writers for the final delta and verification. Compare file
   contents, metadata and hardlink groups, not just total sizes. Preserve the
   untouched source if any check fails.
4. Change the pool's declared branch set to replace the source with the
   verified destination. Apply the change with a controlled restart of the
   mergerfs service after all intended providers are mounted; do not attempt a
   live branch reload. Validate `/srv/media`, authorized writes, hardlinks and
   Jellyfin reads. Follow the measured pod-remount procedure.
5. Only after explicit acceptance may the retired source disk be wiped and
   provisioned as the next empty LUKS/XFS destination. The sequence can be
   media1 → media4, media2 → converted media1, media3 → converted media2,
   leaving converted media3 empty. Labels and branch declarations must describe
   the actual resulting placement, not assume bytes stayed on their old disks.

Before wiping a source, rollback means returning to that intact source. After
wiping it, rollback requires another verified data migration; reverting Nix is
not an undo. The temporary second copy and same-host retained state are not
independent backups. Do not combine an ownership migration, NAS redesign, or
hot/cold mover implementation with this conversion.
