"""Check incus-mount-isolation's decisions against fixed mount tables.

The VM test uses /persist as a plain directory on the root filesystem. On
hvn-hyp1, /persist is its own ZFS dataset, whose peer group also holds
unrelated binds and Incus's storage pool binds. This runs the script's
decision logic, not its mount calls, on a table captured there.

Usage: python3 incus-mount-isolation-decisions.py SCRIPT
"""

import importlib.util
import sys

spec = importlib.util.spec_from_file_location("isolation", sys.argv[1])
isolation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(isolation)

STATE = "/var/lib/incus"
ZFS_OPTIONS = "rw,xattr,posixacl,casesensitive"
MERGERFS_OPTIONS = "rw,user_id=0,group_id=0,default_permissions,allow_other"

# /proc/self/mountinfo on hvn-hyp1 before #24's fix ran (2026-10-10).
PRODUCTION = f"""\
163 1 0:41 / / rw,noatime shared:1 - zfs rpool/local/root {ZFS_OPTIONS}
212 163 0:42 / /persist rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}
47 163 0:42 /var/lib/incus /var/lib/incus rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}
51 163 0:42 /var/lib/incus-storage-pools/incus-compute /var/lib/incus-storage-pools/incus-compute rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}
564 163 0:64 / /srv/media/data rw,nosuid,nodev,relatime shared:399 - fuse.mergerfs /mnt/storage-clear/media4/pool {MERGERFS_OPTIONS}
737 47 0:87 / /var/lib/incus/devices rw,relatime shared:818 - tmpfs tmpfs rw,size=256000k,mode=711
741 212 0:87 / /persist/var/lib/incus/devices rw,relatime shared:818 - tmpfs tmpfs rw,size=256000k,mode=711
848 47 0:93 / /var/lib/incus/shmounts rw,relatime shared:839 - tmpfs tmpfs rw,size=100k,mode=711
850 212 0:93 / /persist/var/lib/incus/shmounts rw,relatime shared:839 - tmpfs tmpfs rw,size=100k,mode=711
993 47 0:94 / /var/lib/incus/guestapi rw,relatime shared:860 - tmpfs tmpfs rw,size=100k,mode=755
995 212 0:94 / /persist/var/lib/incus/guestapi rw,relatime shared:860 - tmpfs tmpfs rw,size=100k,mode=755
1034 47 0:42 /var/lib/incus-storage-pools/incus-compute /var/lib/incus/storage-pools/incus-compute rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}
1036 212 0:42 /var/lib/incus-storage-pools/incus-compute /persist/var/lib/incus/storage-pools/incus-compute rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}
390 741 0:41 /srv/media /persist/var/lib/incus/devices/compute_compute-1/disk.media.srv-media rw,noatime shared:1 - zfs rpool/local/root {ZFS_OPTIONS}
391 390 0:64 / /persist/var/lib/incus/devices/compute_compute-1/disk.media.srv-media/data rw,nosuid,nodev,relatime shared:399 - fuse.mergerfs /mnt/storage-clear/media4/pool {MERGERFS_OPTIONS}
"""

# The same host after the fix ran: mount 47 is private and the copies are gone.
AFTER_FIX = f"""\
163 1 0:41 / / rw,noatime shared:1 - zfs rpool/local/root {ZFS_OPTIONS}
212 163 0:42 / /persist rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}
47 163 0:42 /var/lib/incus /var/lib/incus rw,noatime - zfs rpool/safe/persist {ZFS_OPTIONS}
51 163 0:42 /var/lib/incus-storage-pools/incus-compute /var/lib/incus-storage-pools/incus-compute rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}
564 163 0:64 / /srv/media/data rw,nosuid,nodev,relatime shared:399 - fuse.mergerfs /mnt/storage-clear/media4/pool {MERGERFS_OPTIONS}
737 47 0:87 / /var/lib/incus/devices rw,relatime shared:818 - tmpfs tmpfs rw,size=256000k,mode=711
848 47 0:93 / /var/lib/incus/shmounts rw,relatime shared:839 - tmpfs tmpfs rw,size=100k,mode=711
993 47 0:94 / /var/lib/incus/guestapi rw,relatime shared:860 - tmpfs tmpfs rw,size=100k,mode=755
1034 47 0:42 /var/lib/incus-storage-pools/incus-compute /var/lib/incus/storage-pools/incus-compute rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}
"""

# No persistence bind: /var/lib/incus is a directory on the root filesystem.
UNPERSISTED = f"""\
163 1 0:41 / / rw,noatime shared:1 - zfs rpool/local/root {ZFS_OPTIONS}
737 163 0:87 / /var/lib/incus/devices rw,relatime shared:818 - tmpfs tmpfs rw,size=256000k,mode=711
"""

# /var/lib, not /var/lib/incus, is bound from the /persist dataset.
PARENT = f"""\
163 1 0:41 / / rw,noatime shared:1 - zfs rpool/local/root {ZFS_OPTIONS}
212 163 0:42 / /persist rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}
60 163 0:42 /var/lib /var/lib rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}
737 60 0:87 / /var/lib/incus/devices rw,relatime shared:818 - tmpfs tmpfs rw,size=256000k,mode=711
741 212 0:87 / /persist/var/lib/incus/devices rw,relatime shared:818 - tmpfs tmpfs rw,size=256000k,mode=711
"""

# The same, with /persist a plain directory on the root filesystem, as in the
# VM test.
PARENT_ON_ROOT = """\
1 0 253:1 / / rw,relatime shared:1 - ext4 /dev/vda rw
60 1 253:1 /persist/var/lib /var/lib rw,relatime shared:1 - ext4 /dev/vda rw
737 60 0:87 / /var/lib/incus/devices rw,relatime shared:818 - tmpfs tmpfs rw,size=256000k,mode=711
741 1 0:87 / /persist/var/lib/incus/devices rw,relatime shared:818 - tmpfs tmpfs rw,size=256000k,mode=711
"""


def mounts(table: str, *extra: str) -> list:
    return isolation.parse_mounts(table.splitlines() + list(extra))


def by_id(table: list) -> dict:
    return {mount.id: mount for mount in table}


def refuses(table: list) -> bool:
    try:
        isolation.plan(table, STATE)
    except isolation.Refusal as error:
        print(f"refused: {error}")
        return True
    return False


def check(name: str, condition: bool, detail: object = "") -> None:
    if not condition:
        raise AssertionError(f"{name}: {detail}")
    print(f"ok: {name}")


def planned(name: str, table: list):
    try:
        found = isolation.plan(table, STATE)
    except isolation.Refusal as error:
        raise AssertionError(f"{name}: refused: {error}") from None
    check(f"{name}: a plan", found is not None)
    return found


production = mounts(PRODUCTION)
found = planned("production", production)
check("production: the provider is mount 47", found.provider.id == 47, found.provider)
check("production: the only copy location is /persist/var/lib/incus",
      found.locations == ["/persist/var/lib/incus"], found.locations)
copies = isolation.copies_below(production, found.locations)
expected = sorted(by_id(production)[id].target for id in [741, 850, 995, 1036, 390, 391])
check("production: the copies are mounts 741, 850, 995, 1036, 390 and 391",
      copies == expected, copies)
for id in [51, 1034, 564]:
    check(f"production: mount {id} is not a copy", by_id(production)[id].target not in copies)
check("production: copies are unmounted at devices, shmounts, guestapi and storage-pools/incus-compute",
      isolation.outermost(copies) == [
          "/persist/var/lib/incus/devices",
          "/persist/var/lib/incus/guestapi",
          "/persist/var/lib/incus/shmounts",
          "/persist/var/lib/incus/storage-pools/incus-compute",
      ], isolation.outermost(copies))

name = "a bind of the dataset in another peer group is not a view"
found = planned(name, mounts(
    PRODUCTION,
    f"300 163 0:42 / /mnt/persist rw,noatime shared:20 - zfs rpool/safe/persist {ZFS_OPTIONS}",
))
check(name, found.locations == ["/persist/var/lib/incus"], found.locations)

# A disk device whose source is the whole dataset joins its peer group below
# the state directory, and its copy appears below /persist/var/lib/incus.
name = "a disk device that binds the whole dataset is not a view"
table = mounts(
    PRODUCTION,
    f"1100 737 0:42 / /var/lib/incus/devices/compute_compute-1/disk.persist rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}",
    f"1101 741 0:42 / /persist/var/lib/incus/devices/compute_compute-1/disk.persist rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}",
)
found = planned(name, table)
check(name, found.locations == ["/persist/var/lib/incus"], found.locations)
check(f"{name}: its copy is removed with the others",
      "/persist/var/lib/incus/devices/compute_compute-1/disk.persist" in isolation.copies_below(table, found.locations))

check("after the fix: nothing to do", isolation.plan(mounts(AFTER_FIX), STATE) is None)
check("unpersisted: nothing to do", isolation.plan(mounts(UNPERSISTED), STATE) is None)

check("a second view of / is refused", refuses(mounts(
    UNPERSISTED,
    f"900 163 0:41 / /mnt/root-view rw,noatime shared:1 - zfs rpool/local/root {ZFS_OPTIONS}",
)))
check("a copy location covered by a mount on /persist/var/lib is refused", refuses(mounts(
    PRODUCTION,
    "900 212 0:99 / /persist/var/lib rw,relatime shared:900 - tmpfs tmpfs rw",
)))
check("a copy location hidden by a mount stacked on /persist is refused", refuses(mounts(
    PRODUCTION,
    "900 212 0:99 / /persist rw,relatime shared:900 - tmpfs tmpfs rw",
)))
check("a peer hidden below the live bind is refused", refuses(mounts(
    PRODUCTION.replace("47 163 0:42", "47 46 0:42"),
    f"46 163 0:42 /var/lib/incus /var/lib/incus rw,noatime shared:7 - zfs rpool/safe/persist {ZFS_OPTIONS}",
)))

for name, table in [("parent", PARENT), ("parent on the root filesystem", PARENT_ON_ROOT)]:
    table = mounts(table)
    found = planned(name, table)
    check(f"{name}: the provider is the /var/lib bind", found.provider.id == 60, found.provider)
    check(f"{name}: the copy location is /persist/var/lib/incus",
          found.locations == ["/persist/var/lib/incus"], found.locations)
    check(f"{name}: the copy is mount 741",
          isolation.copies_below(table, found.locations) == ["/persist/var/lib/incus/devices"])
