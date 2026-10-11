"""Keep mounts made below the Incus state directory out of its other views.

When the state directory is provided by a bind mount of a subdirectory, as
impermanence's persistence binds are, the bind is a mount peer of the
filesystem it came from. Every mount Incus makes below the state directory
then also appears at the matching path in each peer: the "copies". Linux does
not remove a copy while it has a child mount, so a disk device whose source
contains a mount leaves a busy copy behind and the instance cannot start
again.

This script reads the kernel mount table, not the system configuration:

1. Find the mount that provides the state directory (the longest mount point
   that contains it).
2. Find where the state directory appears in each peer of that mount.
3. Make the providing mount private, so nothing propagates in either
   direction. This must happen first: unmounting a copy propagates to the
   peers of the copy's parent, which would include the live mount.
4. Remove every mount below those locations, private first and lazily.
5. Read the mount table again and fail unless the providing mount is no
   longer shared and no copy remains.

It changes nothing when the providing mount is not shared or has no peer that
shows the state directory. It refuses, and changes nothing, when the
providing mount is a filesystem's own root mount, because making that mount
private would change propagation for everything on it.
"""

import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Optional


class Refusal(Exception):
    pass


@dataclass(frozen=True)
class Mount:
    id: int
    parent: int
    device: str
    root: str
    target: str
    peer_group: Optional[str]


def unescape(field: str) -> str:
    # mountinfo writes space, tab, newline and backslash as octal escapes.
    return re.sub(r"\\([0-7]{3})", lambda match: chr(int(match.group(1), 8)), field)


def read_mounts() -> list[Mount]:
    mounts = []
    with open("/proc/self/mountinfo", encoding="utf-8") as mountinfo:
        for line in mountinfo:
            fields = line.split()
            optional = fields[6:fields.index("-", 6)]
            groups = [tag.split(":", 1)[1] for tag in optional if tag.startswith("shared:")]
            mounts.append(Mount(
                id=int(fields[0]),
                parent=int(fields[1]),
                device=fields[2],
                root=unescape(fields[3]),
                target=unescape(fields[4]),
                peer_group=groups[0] if groups else None,
            ))
    return mounts


def below(path: str, base: str) -> bool:
    """Whether path is strictly below base."""
    return path != base and path.startswith(base.rstrip("/") + "/")


def at_or_below(path: str, base: str) -> bool:
    return path == base or below(path, base)


def join(base: str, path: str, prefix: str) -> str:
    """base plus the part of path below prefix."""
    return os.path.normpath(os.path.join(base, os.path.relpath(path, prefix)))


def providing_mount(mounts: list[Mount], path: str) -> Mount:
    """The mount that is visible at path, like findmnt --target."""
    holders = [mount for mount in mounts if at_or_below(path, mount.target)]
    longest = max(len(mount.target) for mount in holders)
    stacked = [mount for mount in holders if len(mount.target) == longest]
    # Several mounts at one mount point: the visible one has no mount on top.
    covered = {mount.parent for mount in stacked}
    return next(mount for mount in stacked if mount.id not in covered)


def copy_locations(mounts: list[Mount], provider: Mount, state: str) -> list[tuple[Mount, str]]:
    """Each peer of provider that shows state, with the path state has there."""
    locations = []
    for peer in mounts:
        if (
            peer.id == provider.id
            or peer.peer_group != provider.peer_group
            or peer.device != provider.device
            or not at_or_below(provider.root, peer.root)
            # A disk device can bind the same filesystem below the state
            # directory; that is one of Incus's own mounts, not a view of it.
            or below(peer.target, state)
        ):
            continue
        location = join(join(peer.target, provider.root, peer.root), state, provider.target)
        locations.append((peer, location))
    # A peer below another view is itself a copy and goes with that view.
    return [
        (peer, location) for peer, location in locations
        if not any(below(peer.target, other) for _, other in locations)
    ]


def run(*command: str) -> bool:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(f"{' '.join(command)} failed: {(result.stdout + result.stderr).strip()}", file=sys.stderr)
    return result.returncode == 0


def copies_below(mounts: list[Mount], locations: list[str]) -> list[str]:
    return sorted({
        mount.target for mount in mounts
        if any(below(mount.target, location) for location in locations)
    })


def isolate(state: str) -> None:
    mounts = read_mounts()
    provider = providing_mount(mounts, state)
    described = f"{state} is on mount {provider.id} at {provider.target} (root {provider.root})"
    if provider.peer_group is None:
        print(f"{described}, which is not shared; nothing propagates out of it")
        return
    peers = copy_locations(mounts, provider, state)
    if not peers:
        print(f"{described}, which no other mount shows; nothing to isolate")
        return
    shown = ", ".join(location for _, location in peers)
    if provider.root == "/" or provider.target == "/":
        raise Refusal(
            f"{described} and also appears at {shown}. That mount is a filesystem's "
            "own root mount, and making it private would change propagation for "
            "everything on it; refusing to change it."
        )
    for peer, location in peers:
        holder = providing_mount(mounts, location)
        if holder.id != peer.id or at_or_below(provider.target, location):
            raise Refusal(
                f"{described} and also appears at {location} in mount {peer.id}, but "
                f"mount {holder.id} at {holder.target} covers that path, so copies "
                "there cannot be reached by path; refusing to change anything."
            )

    print(f"{described} and also appears at {shown}")
    if not run("mount", "--make-private", provider.target):
        raise Refusal(f"could not make {provider.target} private")
    print(f"made {provider.target} private")

    locations = [location for _, location in peers]
    # A stacked mount point needs one pass per layer; stop after a few.
    for _ in range(8):
        remaining = copies_below(read_mounts(), locations)
        if not remaining:
            break
        removed: list[str] = []
        for target in remaining:
            # Unmounting a copy also removes everything mounted below it.
            if any(at_or_below(target, done) for done in removed):
                continue
            removed.append(target)
            # Private first, so this unmount cannot propagate anywhere. Lazy,
            # because an open file can hold the copy.
            if run("mount", "--make-rprivate", target) and run("umount", "--recursive", "--lazy", target):
                print(f"removed propagated copy {target}")

    after = read_mounts()
    problems = []
    current = providing_mount(after, state)
    if current.id != provider.id:
        problems.append(f"{state} is now on mount {current.id} at {current.target}, not mount {provider.id}")
    elif current.peer_group is not None:
        problems.append(f"{current.target} is still shared (peer group {current.peer_group})")
    remaining = copies_below(after, locations)
    if remaining:
        problems.append("copies remain: " + ", ".join(remaining))
    if problems:
        raise Refusal("isolation did not hold: " + "; ".join(problems))
    print(f"{state} is isolated: its mount is private and no copy remains")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} STATE_DIRECTORY", file=sys.stderr)
        return 2
    try:
        isolate(os.path.realpath(sys.argv[1]))
    except Refusal as error:
        print(f"incus-mount-isolation: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
