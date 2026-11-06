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

## Root ESP mirror updates and disposable proof

A configured ZFS root mirror uses native udev link priorities to mount
an available configured ESP at `/boot`, including in the initrd.
`/boot` remains required for boot; a single-disk host keeps its existing
device. The bootloader installer explicitly mounts the other available
ESP in a private temporary mount, copies boot entries and pre-unlock
credentials, and generates that ESP's own random seed. An absent member
is skipped; failure to mount an available member fails the update.
No routine activation formats either member.

Switching a running host to the mirror changes the `/boot` device, so
activation remounts `/boot`. Before that remount,
`root-esp-link.service` reloads udev rules and re-runs them on the
present ESPs so that `/dev/disk/root-esp` exists.

These are current implementation details, not an additional fleet-wide
surviving-member guarantee in `storage-foundations`.

On a disposable `x86_64-linux` KVM builder, run:

```sh
nix build .#checks.x86_64-linux.root-esp-mirror -L --no-link
```

The native disko/UEFI scenario installs with the mirror unmounted,
checks distinct ESP random seeds, update propagation, a live switch
that keeps `/boot` mounted, and refusal of an unrelated source mount.
It boots encrypted ZFS with each disk independently absent.

Disposable runtime credentials feed the real Hoopsnake service through
initrd secret files and systemd `LoadCredential`. An unauthorized SSH
key is rejected while ZFS remains locked. Authorized SSH answers the
native password request; boot continues without a harness switch-root.
The scenario checks ephemeral-root rollback, retained state, service
shutdown, and a separate bounded console recovery with networking
disconnected. Its isolated Headscale preauth flow does not prove
public Tailscale OAuth or production tailnet policy.

`core.remote-unlock` includes the Den `core.hoopsnake` aspect. That
aspect patches only the pinned upstream NixOS module for systemd-only
initrd; the Hoopsnake executable is unchanged. Configuration evaluation
imports the committed generated module, without building patched source.
The native `write-files` generator applies the patch and retains the
upstream license. After changing the pin or patch, run
`nix run path:.#write-files` and `nix run path:.#diff-files`.
Do not restore the removed `boot.initrd.systemd.enable` option.

The Impermanence aspect imports pinned official upstream without a
local source patch. The VM scenario checks systemd's resolved
`Requires` and `After` dependencies on the persistence mount in both
initrd and stage 2. Active bind mounts must refer to the same backing
directories, verified by their device and inode identities.

Configuration evaluation is not boot proof. Retain executed VM results
and separately verify physical firmware can select either ESP before
relying on redundancy.

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


