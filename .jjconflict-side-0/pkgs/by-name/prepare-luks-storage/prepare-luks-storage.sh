#!/usr/bin/env bash
# prepare-luks-storage — Partition + luksFormat a fresh disk. DESTROYS
# ALL DATA on the target.
#
# Usage: prepare-luks-storage <by-id-suffix>
# Example: prepare-luks-storage wwn-0x5000cca27061f6b4
#
# The host config must already declare the disk in
# settings.disk.luks-storage.disks.<DISK> with provisioned = false
# (the default), and `agenix generate && agenix rekey` must have run
# on the workstation so the agenix secret is in place. After this
# script, run the recipe at the bottom, then flip provisioned = true
# and redeploy.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <by-id-suffix>" >&2
  exit 64
fi

BY_ID="$1"
DISK="/dev/disk/by-id/${BY_ID}"
PART="/dev/disk/by-id/${BY_ID}-part1"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -b "$DISK" ]] || die "$DISK is not a block device"

if [[ -b "$PART" ]]; then
  die "$PART already exists — refusing to continue
If you really want to wipe, run: wipefs -a $DISK"
fi

# Pull a stable fingerprint of the target disk. The user must type the
# serial number back to confirm — this catches the case where two disks
# share a model string and someone confirms on the wrong one.
DISK_MODEL=$(lsblk -dn -o MODEL "$DISK" | xargs)
DISK_SIZE=$(lsblk -dn -o SIZE "$DISK" | xargs)
DISK_SERIAL=$(lsblk -dn -o SERIAL "$DISK" | xargs)

if [[ -z "$DISK_SERIAL" ]]; then
  die "could not read serial number for $DISK — refusing to continue"
fi

echo "============================================================"
echo "Target disk:    $DISK"
echo "Partition:      $PART"
echo "Model:          $DISK_MODEL"
echo "Size:           $DISK_SIZE"
echo "Serial:         $DISK_SERIAL"
echo "============================================================"
echo
echo "This will DESTROY ALL DATA on $DISK."
echo
printf 'Type the serial number above to confirm: '
read -r confirm
echo
[[ "$confirm" == "$DISK_SERIAL" ]] || {
  echo "Confirmation did not match serial. Aborted."
  exit 1
}

sgdisk --zap-all "$DISK"
sgdisk -n 1:0:0 -t 1:8309 "$DISK"

echo
echo "Format LUKS container. Choose a strong recovery passphrase and"
echo "store it somewhere safe — it's your only way back in if the agenix"
echo "key is ever lost."
echo
cryptsetup luksFormat --type luks2 "$PART"

cat <<EOF

============================================================
LUKS container ready at: $PART
============================================================

The script doesn't know the by-id you ran it with — that's $PART
above. Fill in the placeholders below with values from your host's
Nix config (settings.disk.luks-storage.disks.<DISK>):

  <DISK>      attrset key, e.g. media4
  <MAPPER>    device-mapper name, default crypt-<DISK>
  <FS>        filesystem type, e.g. btrfs
  <FS-LABEL>  filesystem label, e.g. media4-luks
  <mountpoint>  from your host config

  # 1. On the host, as root (you'll need the recovery passphrase):
  cryptsetup open $PART <MAPPER>
  mkfs.<FS> -L <FS-LABEL> /dev/mapper/<MAPPER>
  cryptsetup close <MAPPER>
  cryptsetup luksAddKey $PART /run/agenix/luks-<DISK>-key

  # 2. On the workstation, flip the flag and redeploy:
  #      disk.luks-storage.disks.<DISK>.provisioned = true;

  # 3. Verify:
  systemctl start systemd-cryptsetup@<MAPPER>.service
  mount /dev/mapper/<MAPPER> <mountpoint> && ls <mountpoint>

============================================================
EOF
