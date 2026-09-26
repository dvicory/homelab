<!-- provenance: generated from evaluated Den/Nix declarations by modules/flake/docs/storage.nix; keep the committed copy in sync. -->
# Storage

The declared storage layout per host, generated from evaluated
configuration. It is not a source of authority. The current storage
contract is
[`storage-foundations`](../openspec/specs/storage-foundations/spec.md).
The placement rules are still a proposed change,
[`storage-placement-contract`](../openspec/changes/storage-placement-contract/),
and become current only when that change is archived. The reasoning
behind the namespace and the device encryption lives in [ADR-0006](architecture/decisions/0006-stable-semantic-storage-namespace.md)
and [ADR-0007](architecture/decisions/0007-block-level-encryption-for-data-disks.md);
the disk conversion procedure is in
[`docs/operations/luks-storage-migration.md`](operations/luks-storage-migration.md).

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
| 1 | `/mnt/storage-clear/media1` | yes | yes | `gocryptfs-media1.service` |
| 2 | `/mnt/storage-clear/media2` | yes | yes | `gocryptfs-media2.service` |
| 3 | `/mnt/storage-clear/media3` | yes | yes | `gocryptfs-media3.service` |


### Managed storage roots

| Root | Owner | Group | Mode | Default access |
| --- | --- | --- | --- | --- |
| `/srv/media` | `root` | `media` | `2770` | none |

`Default access` lists the ACL entries a root declares so content
created inside inherits them; `none` means the root declares owner,
group, and mode only. Activation never rewrites ownership, modes, or
access entries of existing content.


