# Live Jellyfin sandbox

This is a manual learning exercise on `hvn-hyp1`, not a production deployment.
Use only the generated sandbox bundle and synthetic media. **Do not run
`nixos-rebuild`, `household-bootstrap`, or the household recovery/test driver.**
The sandbox has no guest SSH, production credentials, real-media attachment,
GPU, public listener, or external network access. Incus containers share the
host kernel: this is not a boundary for running arbitrary hostile code.

Proceed one section at a time. If a check fails, stop and keep the output.
Do not weaken a check or delete existing resources to make it pass.

## 1. Get the bundle — Mac

Use the prepared AMD64 payload when available. To reproduce it yourself, build
`packages.x86_64-linux.jellyfin-sandbox-bundle` with a configured Linux builder;
`--system` alone does not give a Mac the ability to build Linux packages.
Do not build the closure on the space-constrained live host.

```sh
OUT=$(nix build --no-link --print-out-paths \
  .#packages.x86_64-linux.jellyfin-sandbox-bundle)

# Dereference the link farm: do not transfer a Nix-store-dependent directory.
WORK=$(mktemp -d /tmp/jellyfin-sandbox.XXXXXX)
cp -RL "$OUT"/. "$WORK"/
ARCHIVE="$WORK/jellyfin-sandbox-x86_64-linux.tar"
tar -C "$WORK" -cf "$ARCHIVE" \
  guest jellyfin-image.tar manifests.yaml profile.yaml firewall.nft sample.mp4 README.md
(cd "$WORK" && shasum -a 256 jellyfin-sandbox-x86_64-linux.tar \
  > jellyfin-sandbox-x86_64-linux.tar.sha256)

scp "$ARCHIVE" "$ARCHIVE.sha256" daniel@hvn-hyp1:/var/tmp/
```

Keep the archive and checksum. They cover the guest image, pinned Jellyfin
image, selected manifests, profile, firewall, five-second synthetic video,
and this guide. Checksums detect transfer corruption, not malicious provenance;
use artifacts from the reviewed repository revision.

## 2. Unpack — host, as `daniel`

```sh
ssh -t daniel@hvn-hyp1

(
  set -eu
  cd /var/tmp
  sha256sum --check jellyfin-sandbox-x86_64-linux.tar.sha256
  test ! -e jellyfin-sandbox-incoming
  test ! -L jellyfin-sandbox-incoming
  umask 077
  mkdir jellyfin-sandbox-incoming
  tar -xf jellyfin-sandbox-x86_64-linux.tar -C jellyfin-sandbox-incoming
)
```

If extraction failed or the directory already existed, stop. Do not reuse a
partially unpacked directory. Staging is outside the 12 GiB dataset quota and
consumes shared pool space.

## 3. Establish the safety boundary — host, as root

```sh
sudo -i
```

The following commands assume Bash. `c` only selects the sandbox Incus project;
`k` only runs kubectl inside its guest. Neither performs hidden setup.

```sh
set -euo pipefail
export INCUS_SOCKET=/var/lib/incus/unix.socket
PROJECT=homelab-sandbox
INSTANCE=sandbox-1
NETWORK=hl-sandbox0
ROOT=/srv/homelab-sandbox
DATASET=rpool/safe/homelab-sandbox
STAGE=/var/tmp/jellyfin-sandbox-incoming
fail() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
c() { incus --force-local --project "$PROJECT" "$@"; }
k() { c exec "$INSTANCE" -- k3s kubectl "$@"; }

[ "$(hostname)" = hvn-hyp1 ] || fail 'wrong host'
systemctl is-active --quiet incus
[ "$(findmnt -n -o SOURCE -M "$ROOT")" = "$DATASET" ] || fail 'wrong or absent mount'
[ "$(findmnt -n -o FSTYPE -M "$ROOT")" = zfs ] || fail 'not ZFS'
[ "$(zfs get -H -o value mountpoint "$DATASET")" = legacy ] || fail 'unexpected mount policy'
[ "$(zfs get -Hp -o value quota "$DATASET")" = 12884901888 ] || fail 'unexpected quota'
[ "$(zfs get -H -o value encryption "$DATASET")" != off ] || fail 'unencrypted dataset'
[ "$(zfs get -H -o value keystatus "$DATASET")" = available ] || fail 'key unavailable'
[ "$(stat -c '%u:%g:%a' "$ROOT")" = 0:0:700 ] || fail 'unexpected root ownership/mode'

# This first-bring-up recipe deliberately requires an empty Incus instance inventory.
incus --force-local list --all-projects --format=json | jq -e 'length == 0'
incus --force-local project list --format=json | \
  jq -e 'all(.[]; .name != "homelab-sandbox")'
incus --force-local storage list --format=json | \
  jq -e 'all(.[]; .name != "homelab-sandbox")'
incus --force-local network list --format=json | \
  jq -e 'all(.[]; .name != "hl-sandbox0")'

for file in /etc/subuid /etc/subgid; do
  awk -F: '
    NF == 3 {
      start=$2+0; end=start+($3+0)
      if ($1 == "root" && start <= 1000000 && end >= 1065536) covered=1
      if ($1 != "root" && start < 1065536 && end > 1000000) overlap=1
    }
    END { exit !(covered && !overlap) }
  ' "$file" || fail "missing or overlapping subordinate-ID allocation: $file"
done

ip -4 address show
ip -4 route show table all
ss -ltn 'sport = :18096'
nft list ruleset
if nft list table inet sandbox-isolation >/dev/null 2>&1; then
  fail 'sandbox firewall table already exists'
fi
nft --check --file "$STAGE/firewall.nft"
df -h /persist "$ROOT" "$STAGE"
zfs get -Hp used,available,quota "$DATASET"
du -sh "$STAGE"
cat "$STAGE/profile.yaml" "$STAGE/firewall.nft"
```

**Review before proceeding:**

- No existing address or non-default route overlaps `10.211.0.0/24`.
- Nothing listens on host port `18096`; no existing firewall policy uses this sandbox bridge.
- The profile is unprivileged and pins only guest Jellyfin UID/GID `751` to
  host UID/GID `1000751`. Incus allocates the remaining isolated guest map.
  Devices name only the sandbox pool, synthetic media, retained state, NIC and loopback proxy.
- Forwarded traffic through `hl-sandbox0` and new guest-to-host traffic are dropped.
  Existing host firewall tables are not replaced.
- Leave shared host space for staging and Incus's compressed archives under
  `/var/lib/incus/images`. Those archives are **outside** the dataset quota.

The 12 GiB quota is what this exercise was validated against, not a measured
minimum. Steady state is roughly 9.3 GiB for the directory-backed pool, guest
root, K3s image store, Jellyfin image layers, state and media. Only about
2.8 GiB remains, and the guest root is the filesystem kubelet measures for
node-level ephemeral storage. In this exercise kubelet's eviction threshold was
reported as `644245104` bytes, exactly 5% of that filesystem, so the eviction
margin is under 700 MiB.

Image import and container startup are transient high-water marks. A live run
of this exercise crossed that margin: kubelet evicted the Jellyfin pod for
ephemeral-storage pressure, and the same pressure let the CRI image store
garbage-collect the pinned Jellyfin image, so the replacement pod failed with
`Init:ErrImageNeverPull` while the node reported `DiskPressure=False`.

Raising the quota alone does not clear that state. Recover by re-importing the
pinned image, then let the workload start:

```sh
c exec "$INSTANCE" -- k3s ctr images list
c file push "$STAGE/jellyfin-image.tar" "$INSTANCE/tmp/jellyfin-image.tar"
c exec "$INSTANCE" -- k3s ctr images import --local --snapshotter native \
  /tmp/jellyfin-image.tar
c exec "$INSTANCE" -- rm -f /tmp/jellyfin-image.tar
k -n jellyfin rollout restart deployment/jellyfin
k -n jellyfin rollout status deployment/jellyfin --timeout=300s
```

The quota is a ceiling, not reserved capacity, and compressed archive size is
not installed size. Check free space after each import. If the dataset
approaches its limit, stop the sandbox and investigate rather than tolerating
repeated eviction.

## 4. Create only sandbox resources — host

The dataset must still be mounted. All these names must be new.

```sh
for path in "$ROOT/pool" "$ROOT/media" "$ROOT/state"; do
  [ ! -e "$path" ] && [ ! -L "$path" ] || fail "path already exists: $path"
done
install -d -m 0755 "$ROOT/pool" "$ROOT/media" "$ROOT/state"
install -d -o 1000751 -g 1000751 -m 0750 "$ROOT/state/jellyfin-config"
install -m 0644 "$STAGE/sample.mp4" "$ROOT/media/sample.mp4"

incus --force-local storage create homelab-sandbox dir source="$ROOT/pool"
incus --force-local network create "$NETWORK" \
  ipv4.address=10.211.0.1/24 ipv4.dhcp=false ipv4.nat=false ipv6.address=none

incus --force-local project create "$PROJECT" \
  -c features.images=true -c features.profiles=true \
  -c features.storage.volumes=true -c features.networks=false \
  -c restricted=true \
  -c restricted.containers.interception=block \
  -c restricted.containers.lowlevel=block \
  -c restricted.containers.nesting=allow \
  -c restricted.containers.privilege=unprivileged \
  -c restricted.idmap.uid=1000000-1065535 \
  -c restricted.idmap.gid=1000000-1065535 \
  -c restricted.devices.disk=allow \
  -c restricted.devices.disk.paths="$ROOT/media,$ROOT/state/jellyfin-config" \
  -c restricted.devices.proxy=allow -c restricted.devices.nic=managed \
  -c restricted.networks.access="$NETWORK" \
  -c restricted.devices.gpu=block -c restricted.devices.pci=block \
  -c restricted.devices.usb=block -c restricted.devices.infiniband=block \
  -c restricted.devices.unix-block=block -c restricted.devices.unix-char=block \
  -c restricted.devices.unix-hotplug=block

c profile create "$INSTANCE"
c profile edit "$INSTANCE" < "$STAGE/profile.yaml"
nft --file "$STAGE/firewall.nft"

incus --force-local storage show homelab-sandbox
incus --force-local network show "$NETWORK"
incus --force-local project show "$PROJECT"
c profile show "$INSTANCE"
nft list table inet sandbox-isolation
```

Check the resulting values against the bundle before creating a guest. The
state owner is mapped Jellyfin UID/GID `751:751`; the synthetic media remains
root-owned and is attached read-only. Do not use recursive `chown` as a repair.

## 5. Import and start the guest — host

If `c init` failed with `Host ID is in the range of subids` using the original
bundle, correct the existing profile before retrying:

```sh
c profile set "$INSTANCE" raw.idmap="both 1000751 751"
c profile show "$INSTANCE"
```

Keep `restricted.containers.lowlevel=block` and `security.idmap.isolated=true`.
The old bundle's `profile.yaml` contains the full-range mapping; do not reapply
it. No image rebuild, ownership change, or resource deletion is needed.
Retry the `c init` command below with the already imported image.

```sh
c image import "$STAGE/guest/metadata.tar.xz" "$STAGE/guest/rootfs.tar.xz" \
  --alias sandbox-image
c image list
df -h "$ROOT" /persist
zfs get -Hp used,available,quota "$DATASET"
```

Image import is not guest startup. Inspect storage consumption before the next
step: the `dir` backend also needs an instance-root copy.

```sh
c init sandbox-image "$INSTANCE" --profile "$INSTANCE"
c config show "$INSTANCE" --expanded
```

Verify the expanded configuration has no extra host paths or privileged mode.
Then start and inspect:

```sh
c start "$INSTANCE"
c info "$INSTANCE"
c exec "$INSTANCE" -- systemctl status k3s --no-pager
```

K3s can take time to initialize. If it is still starting, inspect again before
proceeding; if failed, use `journalctl -u k3s` through `c exec`. Once its API is
available:

```sh
k wait --for=condition=Ready node/sandbox-1 --timeout=300s
k get nodes -o wide
k get pods -A -o wide
k get --raw='/readyz?verbose'
```

Expected: node `sandbox-1`, address `10.211.0.10`, Ready, and healthy API checks.
Do not proceed on an Incus `RUNNING` status alone. There is no guest SSH login.

## 6. Install the offline application — host

```sh
c file push "$STAGE/jellyfin-image.tar" "$INSTANCE/tmp/jellyfin-image.tar"
c exec "$INSTANCE" -- k3s ctr images import --local --snapshotter native \
  /tmp/jellyfin-image.tar
c exec "$INSTANCE" -- rm /tmp/jellyfin-image.tar
c exec "$INSTANCE" -- k3s ctr images list
zfs get -Hp used,available,quota "$DATASET"
```

The manifest uses this pinned image with `imagePullPolicy: Never`. Do not
substitute a registry pull or enable internet access if import fails.

```sh
c exec "$INSTANCE" -- k3s kubectl apply --server-side \
  --field-manager=jellyfin-sandbox -f - < "$STAGE/manifests.yaml"
k -n jellyfin rollout status deployment/jellyfin --timeout=600s
k -n jellyfin get pods,svc,pvc -o wide
k -n jellyfin get events --sort-by=.lastTimestamp
k -n jellyfin exec deployment/jellyfin -- \
  sh -ec 'test -r /media/data/sample.mp4; grep " /media/data " /proc/self/mountinfo'
ss -ltn 'sport = :18096'
curl --fail --silent --show-error http://127.0.0.1:18096/health
```

Expected: a ready Jellyfin deployment, bound retained PVC, synthetic media,
and a successful health response. The proxy listener must be **only**
`127.0.0.1:18096`, never a wildcard/LAN address. Apply success alone is not readiness.

## 7. Learn through the browser — Mac

Keep this separate terminal open:

```sh
ssh -N -T -o ExitOnForwardFailure=yes \
  -L 18096:127.0.0.1:18096 daniel@hvn-hyp1
```

Open <http://127.0.0.1:18096>:

1. Complete the native Jellyfin wizard with a disposable local account.
   Keep its password out of commands, logs and repository files.
2. Add a **Home Videos** library pointing to `/media/data`. Disable online
   metadata providers; do not add real media, external providers or port mapping.
3. Scan the library and play the five-second synthetic sample.

This tests the actual application, writable state, read-only media and access
path. It does not establish backups, GPU support or production readiness.

## 8. Optional guest replacement — explicit destructive step

Do this only after successful playback and after you choose to test replacement.
Reuse the same image and bundle first; there is no need to delete/rebuild images.
Close the browser tunnel and, in the root host shell, recheck the dataset:

```sh
[ "$(findmnt -n -o SOURCE -M "$ROOT")" = "$DATASET" ] || fail 'dataset is not mounted'
[ "$(stat -c '%u:%g:%a' "$ROOT/state/jellyfin-config")" = 1000751:1000751:750 ] \
  || fail 'unexpected retained-state ownership'
c stop "$INSTANCE" --timeout=120
c info "$INSTANCE"
```

Confirm `STOPPED`, then delete **only this guest root**:

```sh
c delete "$INSTANCE"
test -d "$ROOT/state/jellyfin-config"
test -r "$ROOT/media/sample.mp4"
c init sandbox-image "$INSTANCE" --profile "$INSTANCE"
c start "$INSTANCE"
```

Repeat the Kubernetes readiness checks and Section 6. Open the tunnel again.
Your existing account and library should remain; a fresh setup wizard or missing
state is a failure to investigate, not an invitation to configure it again.

## Failure and persistence boundaries

- Stop on missing mounts, conflicts, unexpected paths, insufficient space,
  failed readiness, or a non-loopback listener. Preserve diagnostics and state.
- `c stop "$INSTANCE" --timeout=120` stops the sandbox; do not stop Incus itself.
- Never use blanket resource deletion, `nft flush ruleset`, `zfs destroy`, or
  remove the retained directories as troubleshooting steps.
- This procedure changes no host NixOS configuration. The dataset is durable,
  but its **manual mount and the firewall table are not reboot-persistent**.
  Guest autostart is disabled. Do not reboot as part of this exercise.
- Do not start after a host reboot until the correct dataset is mounted and
  the sandbox firewall is restored. Reboot persistence needs its own Nix change.
- The live sandbox is the runtime test. A full local playback/replacement
  rehearsal is not a prerequisite for following these gated steps.
