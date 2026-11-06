<!-- provenance: generated from evaluated Den/Nix declarations by modules/flake/docs/storage.nix; keep the committed copy in sync. -->
# Storage

The declared storage layout per host, generated from evaluated
configuration. It is not a source of authority. The current storage
contract is
[`storage-foundations`](../openspec/specs/storage-foundations/spec.md).
Proposed placement rules are in
[`storage-placement-contract`](../openspec/changes/storage-placement-contract/).
Follow the current specs rather than treating an active proposal as adopted.
The reasoning behind the namespace and the device encryption lives in [ADR-0006](architecture/decisions/0006-stable-semantic-storage-namespace.md)
and [ADR-0007](architecture/decisions/0007-block-level-encryption-for-data-disks.md);
the disk conversion procedure is in
[`docs/operations/luks-storage-migration.md`](operations/luks-storage-migration.md).

## Update mirrored root boot files

Keep `/boot` mounted for bootloader updates. The installer copies boot
entries and pre-unlock credentials to each other available configured
ESP in a private mount. An absent member is skipped; failure to mount
an available member fails the update. Routine activation does not format
either member. Investigate an update failure rather than formatting an
ESP or bypassing its mount checks.

Switching a running host to the mirrored layout remounts `/boot`.
Before relying on redundancy, obtain authorization for a maintenance
window and verify that firmware can select either physical ESP and that
boot and unlock work with each disk independently absent. Configuration
evaluation and disposable verification are not proof of the physical
host's boot path. The current guarantees remain those in
[`storage-foundations`](../openspec/specs/storage-foundations/spec.md).

## `hvn-hyp1`

### LUKS data disks

| Disk | Declared device | Mapper | Mountpoint | Filesystem | Discard | Provisioned |
| --- | --- | --- | --- | --- | --- | --- |
| `media4` | `/dev/disk/by-id/wwn-0x5000cca27061f6b4-part1` | `crypt-media4` | `/mnt/storage-clear/media4` | `xfs` | no | yes |

`Provisioned = no` declares only the wrapper and the agenix key path.
`yes` adds the crypttab row and the direct mount. Neither value proves
physical work ran.

### mergerfs pools

Branches are listed in declaration order. `Create = no` keeps existing
content readable but excludes the branch from new writes.
`Required = yes` makes an unmounted branch refuse the whole pool; the
pool unit binds to each required branch's mount unit.

Pool `/srv/media/data`:

| # | Branch | Create | Required | Mount unit |
| --- | --- | --- | --- | --- |
| 1 | `/mnt/storage-clear/media4/pool` | yes | yes | the `fileSystems` mount of `/mnt/storage-clear/media4` |


### Managed storage roots

| Root | Owner | Group | Mode | Default access |
| --- | --- | --- | --- | --- |
| `/srv/media` | `root` | `media` | `2770` | none |

`Default access` lists the ACL entries a root declares so content
created inside inherits them; `none` means the root declares owner,
group, and mode only. Activation never rewrites ownership, modes, or
access entries of existing content.


