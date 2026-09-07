# Jellyfin recovery

Configuration lives in [jellyfin.nix](jellyfin.nix), the
[compute aspect](../virtualization/compute.nix), and the
[host declaration](../../hosts/hvn-hyp1/default.nix). This file keeps only the
operator steps that those declarations do not perform.

Production inspection, secret provisioning, deployment, and destructive recovery
require separate authorization. Do not change existing storage, legacy Hermes,
UID ownership, or isolation to make a check pass.

## Recovery inputs

Retain the declared application data and runtime identity, the reviewed source,
and the selected guest/application closures outside the guest. Guest root and
K3s state are disposable. Same-host copies do not protect against host loss.
Jellyfin setup happens once; reconstruction must reuse its retained state.

## Build and create

From the repository root, set `FLAKE` to the approved immutable source reference
and `HOST` to the verified host SSH destination. These are x86_64 production
artifacts; use an authorized builder, not the production host for development.

```sh
BUNDLE=$(nix build --no-link --print-out-paths \
  "$FLAKE#nixosConfigurations.compute-1.config.system.build.computeBundle")
APP=$(nix build --no-link --print-out-paths \
  "$FLAKE#packages.x86_64-linux.jellyfin-kubernetes")
export NIX_SSHOPTS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$PWD/modules/den/hosts/hvn-hyp1/known_hosts"
nix copy --to "ssh-ng://$HOST" "$BUNDLE" "$APP"
```

Before host activation, compare existing Incus resources with the evaluated
preseed; preseed can overwrite existing objects. Check encryption/mounts,
capacity, subordinate-ID and route collisions, and media access. Provision the
identity through the existing agenix/rekey flow. No identity generator is
provided. Host management must work independently of guest SSH and Kubernetes.

On the authorized host, as root, use the copied bundle:

```sh
compute-guest inspect
compute-guest create --bundle "$BUNDLE"
```

Creation does not install Jellyfin. Deliver the selected application below.

## Maintenance shell

Serialize application maintenance and OS activation with guest replacement and
identity staging. Enter on the host:

```sh
sudo flock -n /run/lock/compute-compute-compute-1.lock bash
set -euo pipefail
export INCUS_SOCKET=/var/lib/incus/unix.socket
guest() {
  incus --force-local --project compute exec compute-1 --mode=non-interactive -- "$@"
}
STATE=/var/lib/homelab/compute-1/jellyfin
RECOVERY=/var/lib/homelab/compute-1/recovery
MANIFESTS=/var/lib/rancher/k3s/server/manifests
```

Check these paths against `/etc/homelab/compute.json`; set `APP` and `BUNDLE` to
the selected immutable artifacts. Stay in this shell for the whole operation.
Do not invoke `compute-guest` or restart identity staging inside it: they acquire
the same lock. On failure, leave the workload paused and investigate; do not
continue into deletion or a new application version. Exit releases the lock.

## Deliver the selected application

For upgrades, checkpoint first. Validate the artifact, retain its closure,
import its image, and atomically publish its manifests:

```sh
for member in image-reference image.tar retained.yaml workload.yaml; do
  test -f "$APP/$member"
done
mkdir -p /nix/var/nix/gcroots/homelab-applications
nix-store --add-root "/nix/var/nix/gcroots/homelab-applications/$(basename "$APP")" --realise "$APP"
incus --force-local --project compute file push "$APP/image.tar" compute-1/tmp/jellyfin-image.tar
guest k3s ctr images import --local --snapshotter native /tmp/jellyfin-image.tar
guest rm /tmp/jellyfin-image.tar
for member in retained workload; do
  incus --force-local --project compute file push "$APP/$member.yaml" "compute-1/tmp/jellyfin-$member.yaml"
  guest mv "/tmp/jellyfin-$member.yaml" "$MANIFESTS/jellyfin-$member.yaml"
done
guest rm -f "$MANIFESTS/jellyfin-workload.yaml.skip"
guest k3s kubectl -n jellyfin wait --for=create deployment/jellyfin --timeout=120s
guest k3s kubectl -n jellyfin scale deployment/jellyfin --replicas=1
guest k3s kubectl -n jellyfin rollout status deployment/jellyfin --timeout=300s
```

Check container and init-container images against `"$APP/image-reference"`.
Record the selected artifact; recovery must not silently select a newer release.
Retire objects by removing them from their still-present workload manifest and
verifying native AddOn pruning before deleting the file. Do not delete retained
resources or the namespace as shorthand for workload retirement.

For private access, forward the declared NodePort through the verified host,
bound only to `127.0.0.1`. Keep guest SSH trust separate from host trust; never
accept incident-time `ssh-keyscan` output as verification or forward an agent.
Configure the initial Jellyfin library under `/media/data`. Verify login,
indexing, playback, and a recorded watched/favorite/playback state.

## Checkpoint before an application upgrade

`APP` must be the running release, not the proposed upgrade. Verify its image
and manifests against the running workload. Under the maintenance lock:

```sh
POINT="$RECOVERY/$(date +%s)-checkpoint"
required=$(du -sb "$STATE" | cut -f1)
available=$(df -B1 --output=avail "$RECOVERY" | tail -n1)
test "$available" -ge "$((3 * required + 1073741824))"
guest touch "$MANIFESTS/jellyfin-workload.yaml.skip"
guest k3s kubectl -n jellyfin scale deployment/jellyfin --replicas=0
guest k3s kubectl -n jellyfin wait --for=delete pod -l app.kubernetes.io/name=jellyfin --timeout=120s
test -z "$(guest k3s crictl ps --label io.kubernetes.pod.namespace=jellyfin -q)"
mkdir -m 0700 "$POINT"
nix-store --add-root "$POINT/application" --indirect --realise "$APP"
cp -a --reflink=auto "$STATE" "$POINT/config"
sync -f "$POINT"
touch "$POINT/complete"
sync -f "$POINT"
```

Keep incomplete points out of recovery selection. Do not resume or upgrade
after a failed copy. For an upgrade, select the reviewed new `APP` and deliver
it. For checkpoint-only maintenance, remove the skip marker, scale to one, and
verify playback. Removing a skip marker alone does not undo a scale-to-zero.

## Restore paired data and software

Obtain approval to discard application changes since the selected `POINT`.
Never select a point implicitly by timestamp. Under the maintenance lock:

```sh
test "$(dirname "$POINT")" = "$RECOVERY"
test -f "$POINT/complete"
test -d "$POINT/config"
APP=$(readlink -f "$POINT/application")
nix-store --realise "$APP"
required=$(du -sb "$POINT/config" | cut -f1)
live=$(du -sb "$STATE" | cut -f1)
available=$(df -B1 --output=avail "$RECOVERY" | tail -n1)
test "$available" -ge "$((required + live + 1073741824))"
guest touch "$MANIFESTS/jellyfin-workload.yaml.skip"
guest k3s kubectl -n jellyfin scale deployment/jellyfin --replicas=0
guest k3s kubectl -n jellyfin wait --for=delete pod -l app.kubernetes.io/name=jellyfin --timeout=120s
test -z "$(guest k3s crictl ps --label io.kubernetes.pod.namespace=jellyfin -q)"
incus --force-local --project compute stop compute-1 --timeout=120
DISPLACED="$RECOVERY/$(date +%s)-displaced"
test ! -e "$DISPLACED"
cp -a --reflink=auto "$STATE" "$DISPLACED"
sync -f "$DISPLACED"
find "$STATE" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a --reflink=auto "$POINT/config/." "$STATE"
sync -f "$STATE"
incus --force-local --project compute start compute-1
```

Do not rename/remove `STATE`: it is an impermanence bind mount. Before restart,
keep both the skip marker and zero replicas; the marker alone does not stop an
existing Deployment. Deliver the paired `APP`, then verify login, library,
recorded state, ownership, and playback. Preserve the checkpoint and displaced
data if restoration fails. Software downgrade alone does not undo migration.

If the guest/cluster is already lost, reconstruct compute with the selected
bundle instead of running quiesce commands against an absent cluster. Restore
only with no guest writer, then deliver only the paired application release.

## Replace compute or activate its OS

Leave the maintenance shell and obtain explicit guest-deletion authorization:

```sh
compute-guest replace --bundle "$BUNDLE" --confirm compute-1
```

The helper preserves declared external inputs and does not deliver applications.
Enter maintenance again, deliver the selected `APP`, and verify a fresh guest
root/cluster with the same application state and playable media, without setup.
Repeat this acceptance twice on the production target only after authorization.

OS activation is separate. Under the maintenance lock:

```sh
SYSTEM=$(readlink -f "$BUNDLE/system")
nix-store --realise "$SYSTEM"
mkdir -p /nix/var/nix/gcroots/homelab-compute
nix-store --add-root "/nix/var/nix/gcroots/homelab-compute/$(basename "$BUNDLE")" --realise "$BUNDLE"
nix-store --export $(nix-store --query --requisites "$SYSTEM") | guest nix-store --import
guest nix-env --profile /nix/var/nix/profiles/system --set "$SYSTEM"
guest "$SYSTEM/bin/switch-to-configuration" switch
incus --force-local --project compute config set compute-1 "user.homelab.bundle=$BUNDLE"
guest systemctl is-active sshd k3s
guest k3s kubectl get nodes
```

Do not activate after a failed copy. Verify the independently delivered
application remains usable. Deployment-frontend choice remains open.

For identity re-staging, exit maintenance before restarting
`compute-stage-identity.service`. For rotation, first stop guest SSH under the
lock; update/rekey the encrypted identity and declared public key together,
activate and verify staging, independently update guest trust, and restart SSH
under the lock. Keep the old encrypted identity for recovery; do not change the
host's independent management identity.

## Verification entry point

The [recovery test](../../../tests/jellyfin-recovery.nix) exercises the disposable
slice. Linux check: `checks.x86_64-linux.jellyfin-recovery`; local Apple test:
`legacyPackages.aarch64-darwin.jellyfin-recovery-test`. Local success does not
prove target compatibility, physical-host recovery, or independent backup.
