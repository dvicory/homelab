#!/usr/bin/env bash
# shellcheck disable=SC2016 # Nested bash -c programs intentionally use single quotes.
# Shared implementation for phase0-hvn-hyp1.sh and phase0-proxmox.sh.
# Read-only by design: this script inventories state but never changes system
# configuration, mounts, pools, disks, guests, or services.

set -uo pipefail
umask 077
# Do not execute same-directory or user-controlled command shadows under sudo.
PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

ROLE=${PHASE0_ROLE:-}
LABEL=""
OUTPUT_PARENT=${PWD}
DEEP=0
INCLUDE_PATHS=0
SKIP_SMART=0
MAKE_ARCHIVE=1
COMMAND_TIMEOUT=90
DEEP_TIMEOUT=3600
SCAN_ROOTS=()

usage() {
  cat <<'EOF'
Usage: phase0-<host>.sh [options]

Options:
  --label NAME          Label for this machine in the report.
  --output DIR          Parent directory for output (default: current directory).
  --scan-root PATH      Deep-scan a content root; repeat as needed.
  --deep                Run potentially long, read-only content scans.
  --include-paths       Add a second full traversal for depth-two directory sizes.
                        Paths can reveal media titles and personal information.
  --skip-smart          Skip SMART/NVMe/SnapRAID health probes entirely.
  --command-timeout SEC Timeout for ordinary commands (default: 90).
  --deep-timeout SEC    Timeout for each deep scan command (default: 3600).
  --no-archive          Leave the report directory without creating tar.gz.
  -h, --help            Show this help.

Run as root for complete SMART, DMI, IPMI, storage, and virtualization data.
The report contains sensitive infrastructure metadata: hostnames, IP/MAC
addresses, disk serials, VM names, filesystem paths, and possibly media titles.
Review it before sharing. The script intentionally does not collect secret file
contents, SSH private keys, environment variables, command histories, or tailnet
peer/account rosters.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --label)
      (($# >= 2)) || die "--label requires a value"
      LABEL=$2
      shift 2
      ;;
    --output)
      (($# >= 2)) || die "--output requires a value"
      OUTPUT_PARENT=$2
      shift 2
      ;;
    --scan-root)
      (($# >= 2)) || die "--scan-root requires a value"
      SCAN_ROOTS+=("$2")
      shift 2
      ;;
    --deep)
      DEEP=1
      shift
      ;;
    --include-paths)
      INCLUDE_PATHS=1
      shift
      ;;
    --skip-smart)
      SKIP_SMART=1
      shift
      ;;
    --command-timeout)
      (($# >= 2)) || die "--command-timeout requires a value"
      COMMAND_TIMEOUT=$2
      shift 2
      ;;
    --deep-timeout)
      (($# >= 2)) || die "--deep-timeout requires a value"
      DEEP_TIMEOUT=$2
      shift 2
      ;;
    --no-archive)
      MAKE_ARCHIVE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ "$ROLE" == "hvn-hyp1" || "$ROLE" == "proxmox" ]] || die "collector role was not set by its wrapper"
[[ "$COMMAND_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--command-timeout must be a positive integer"
[[ "$DEEP_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--deep-timeout must be a positive integer"
[[ $(uname -s) == Linux ]] || die "this collector supports Linux hosts only"

HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf unknown)
[[ -n "$LABEL" ]] || LABEL=$HOST
SAFE_LABEL=$(printf '%s' "$LABEL" | tr -cs 'A-Za-z0-9._-' '_')
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT=$(readlink -f "$OUTPUT_PARENT")
OUT="$OUTPUT_PARENT/phase0-${SAFE_LABEL}-${STAMP}"
COMMAND_LOG="$OUT/00-command-log.tsv"
WARNINGS="$OUT/00-warnings.txt"
mkdir -p "$OUT"
printf 'section\tcommand\texit_code\tduration_seconds\n' > "$COMMAND_LOG"
: > "$WARNINGS"

have() {
  command -v "$1" >/dev/null 2>&1
}

sanitize_file() {
  local file=$1 tmp
  tmp="${file}.sanitized"
  # Defense in depth. Commands are selected to avoid credentials, but redact
  # common inline credential forms if a tool unexpectedly prints one.
  sed -E \
    -e 's/((password|passwd|passphrase|secret|auth[_-]?token|access[_-]?token|private[_-]?key)[[:alnum:]_.-]*[[:space:]]*[:=][[:space:]]*)[^,[:space:]"}]+/\1<redacted>/Ig' \
    -e 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1<redacted>@#g' \
    "$file" > "$tmp" 2>/dev/null || cp "$file" "$tmp"
  mv "$tmp" "$file"
}

command_string() {
  printf '%q ' "$@"
}

capture_timeout() {
  local section=$1 seconds=$2
  shift 2
  local file="$OUT/${section}.txt" start end rc cmd
  start=$(date +%s)
  cmd=$(command_string "$@")
  {
    echo "# $section"
    echo "# command: $cmd"
    echo "# started_utc: $(date -u +%FT%TZ)"
    echo
    if ! have "$1" && [[ "$1" != /* ]]; then
      echo "NOT INSTALLED: $1"
      rc=127
    elif have timeout; then
      timeout --signal=TERM --kill-after=10 "$seconds" "$@"
      rc=$?
    else
      "$@"
      rc=$?
    fi
    echo
    echo "# exit_code: $rc"
  } > "$file" 2>&1
  end=$(date +%s)
  sanitize_file "$file"
  printf '%s\t%s\t%s\t%s\n' "$section" "$cmd" "$rc" "$((end - start))" >> "$COMMAND_LOG"
  if ((rc != 0 && rc != 127)); then
    printf '%s: command exited %s; inspect %s.txt\n' "$section" "$rc" "$section" >> "$WARNINGS"
  fi
  return 0
}

capture() {
  local section=$1
  shift
  capture_timeout "$section" "$COMMAND_TIMEOUT" "$@"
}

capture_shell_timeout() {
  local section=$1 seconds=$2 script=$3
  shift 3
  capture_timeout "$section" "$seconds" bash -c "$script" bash "$@"
}

capture_shell() {
  local section=$1 script=$2
  shift 2
  capture_shell_timeout "$section" "$COMMAND_TIMEOUT" "$script" "$@"
}
capture_deep_shell_timeout() {
  local section=$1 seconds=$2 script=$3
  shift 3
  if have ionice; then
    capture_timeout "$section" "$seconds" ionice -c 3 nice -n 19 bash -c "$script" bash "$@"
  else
    capture_timeout "$section" "$seconds" nice -n 19 bash -c "$script" bash "$@"
  fi
}


capture_existing_file() {
  local section=$1 file=$2
  if [[ -r "$file" ]]; then
    capture "$section" cat "$file"
  else
    printf '%s is absent or unreadable\n' "$file" > "$OUT/${section}.txt"
  fi
}

add_default_scan_root() {
  local path=$1 existing
  [[ -d "$path" ]] || return 0
  for existing in "${SCAN_ROOTS[@]:-}"; do
    [[ "$existing" == "$path" ]] && return 0
  done
  SCAN_ROOTS+=("$path")
}

cat > "$OUT/00-metadata.txt" <<EOF
label=$LABEL
role=$ROLE
hostname=$HOST
started_utc=$(date -u +%FT%TZ)
collector_version=2
collector_uid=$(id -u)
collector_user=$(id -un 2>/dev/null || true)
deep=$DEEP
include_paths=$INCLUDE_PATHS
skip_smart=$SKIP_SMART
ordinary_timeout_seconds=$COMMAND_TIMEOUT
deep_timeout_seconds=$DEEP_TIMEOUT
kernel=$(uname -srmo)
output=$OUT
EOF

if ((EUID != 0)); then
  echo "Collector is not running as root; hardware, storage, IPMI, and Proxmox results will be incomplete." >> "$WARNINGS"
fi
echo "Read-only inventory is not zero-impact: storage and management status queries may touch devices or remote backends." >> "$WARNINGS"
if ((DEEP)); then
  echo "Deep mode traverses every file under each explicit root; run it only when production metadata I/O is acceptable." >> "$WARNINGS"
fi

printf 'Collecting Phase 0 inventory for %s (%s). Read-only, but not zero-impact.\n' "$LABEL" "$ROLE"
((SKIP_SMART)) && echo "SMART/NVMe/SnapRAID health probes: skipped"
((DEEP)) && echo "Deep content traversal: enabled for ${#SCAN_ROOTS[@]} root(s)"
echo "Warnings and command status: $WARNINGS"

# Operating system and boot state.
capture "10-system-uname" uname -a
capture_existing_file "10-system-os-release" /etc/os-release
capture "10-system-hostnamectl" hostnamectl
capture "10-system-localectl" localectl
capture "10-system-timedatectl" timedatectl
capture "10-system-uptime" uptime
capture "10-system-kernel-command-line" cat /proc/cmdline
capture "10-system-bootctl" bootctl status --no-pager
capture "10-system-systemd-failed" systemctl --failed --no-pager
capture "10-system-running-services" systemctl list-units --type=service --state=running --no-pager
capture "10-system-enabled-units" systemctl list-unit-files --state=enabled --no-pager
capture "10-system-timers" systemctl list-timers --all --no-pager
capture "10-system-kernel-errors-current-boot" journalctl -k -b -p warning..alert --no-pager -n 2000
capture "10-system-reboots" last -x -n 50

# Chassis, firmware, CPU, memory, NUMA, and platform capability.
capture "20-hardware-dmidecode" dmidecode --type 0,1,2,3,4,16,17,39,41
capture "20-hardware-lscpu" lscpu --all --extended
capture "20-hardware-lscpu-json" lscpu --json
capture "20-hardware-numactl" numactl --hardware
capture "20-hardware-memory" free -h
capture "20-hardware-meminfo" cat /proc/meminfo
capture "20-hardware-edac" ras-mc-ctl --status
capture "20-hardware-ras-errors" ras-mc-ctl --errors
capture "20-hardware-mcelog" mcelog --client
capture "20-hardware-lshw" lshw -json
capture "20-hardware-lspci" lspci -Dnnk
capture "20-hardware-lspci-verbose" lspci -Dvvnn
capture "20-hardware-pci-tree" lspci -Dtv
capture "20-hardware-iommu-groups" bash -c 'for g in /sys/kernel/iommu_groups/*; do [[ -d "$g" ]] || continue; echo "GROUP ${g##*/}"; for d in "$g"/devices/*; do [[ -e "$d" ]] && printf "  %s -> %s\n" "${d##*/}" "$(readlink -f "$d")"; done; done'
capture "20-hardware-usb" lsusb -tv
capture "20-hardware-usb-ids" lsusb
capture "20-hardware-sensors" sensors -A
capture "20-hardware-ipmi-sensors" ipmitool sensor
capture "20-hardware-ipmi-sdr" ipmitool sdr elist all
capture "20-hardware-ipmi-fru" ipmitool fru print
capture "20-hardware-ipmi-power" ipmitool dcmi power reading
capture "20-hardware-powercap" bash -c 'for f in /sys/class/powercap/*/{name,energy_uj,max_energy_range_uj}; do [[ -r "$f" ]] && printf "%s=" "$f" && cat "$f"; done'

# GPU/media capability, especially the Intel adapter intended for Jellyfin.
capture "30-gpu-drm-tree" bash -c 'for d in /sys/class/drm/card* /sys/class/drm/renderD*; do [[ -e "$d" ]] || continue; echo "== $d =="; readlink -f "$d/device"; for f in vendor device subsystem_vendor subsystem_device; do [[ -r "$d/device/$f" ]] && printf "%s=" "$f" && cat "$d/device/$f"; done; done; stat -c "%A %U:%G %t:%T %n" /dev/dri/* 2>/dev/null || true'
capture "30-gpu-vainfo" vainfo
capture "30-gpu-ffmpeg-hwaccels" ffmpeg -hide_banner -hwaccels
capture "30-gpu-ffmpeg-encoders" bash -c 'ffmpeg -hide_banner -encoders 2>/dev/null | grep -Ei "vaapi|qsv|nvenc|vulkan|videotoolbox|amf" || true'
capture "30-gpu-ffmpeg-decoders" bash -c 'ffmpeg -hide_banner -decoders 2>/dev/null | grep -Ei "qsv|cuvid|v4l2|vulkan" || true'
capture "30-gpu-i915-module" modinfo i915
capture "30-gpu-kernel-log" bash -c 'journalctl -k -b --no-pager | grep -Ei "drm|i915|xe|firmware|guc|huc" || true'

# Block devices, filesystems, encryption, pools, and health.
capture "40-storage-lsblk" lsblk --json --bytes -O
capture "40-storage-block-topology" lsblk -e 7 -o NAME,KNAME,PATH,TYPE,SIZE,ROTA,TRAN,HCTL,MODEL,SERIAL,WWN,REV,PHY-SEC,LOG-SEC,MIN-IO,OPT-IO,ALIGNMENT,FSTYPE,FSVER,LABEL,UUID,PARTUUID,MOUNTPOINTS
capture "40-storage-by-id" bash -c 'for p in /dev/disk/by-id/*; do [[ -L "$p" ]] && printf "%s -> %s\n" "$p" "$(readlink -f "$p")"; done | sort'
capture "40-storage-findmnt" findmnt --json --bytes -A
capture "40-storage-df-local" df -lhT
capture "40-storage-inodes-local" df -liT
capture_existing_file "40-storage-fstab" /etc/fstab
capture_existing_file "40-storage-crypttab" /etc/crypttab
capture_existing_file "40-storage-mdadm-conf" /etc/mdadm.conf
capture_existing_file "40-storage-snapraid-conf" /etc/snapraid.conf
capture "40-storage-blkid" blkid
capture "40-storage-cryptsetup-status" bash -c 'for d in /dev/mapper/*; do [[ -b "$d" ]] || continue; n=${d##*/}; echo "== $n =="; cryptsetup status "$n" 2>&1 || true; done'
capture "40-storage-luks-metadata" bash -c 'lsblk -rpn -o PATH,FSTYPE | while read -r d t; do [[ "$t" == crypto_LUKS ]] || continue; echo "== $d =="; cryptsetup luksDump "$d" 2>&1 || true; done'
capture "40-storage-mdadm" mdadm --detail --scan --verbose
capture "40-storage-proc-mdstat" cat /proc/mdstat
capture "40-storage-pvs" pvs --reportformat json --units b -a -o+pv_used,pv_free,dev_size
capture "40-storage-vgs" vgs --reportformat json --units b -a -o+vg_free,vg_size
capture "40-storage-lvs" lvs --reportformat json --units b -a -o+devices,segtype,data_percent,metadata_percent
capture "40-storage-zpool-list" zpool list -v -p
capture "40-storage-zpool-status" zpool status -LPv
capture "40-storage-zpool-properties" zpool get all
capture "40-storage-zfs-list" zfs list -t filesystem,volume -o name,used,available,referenced,mountpoint,compression,compressratio,recordsize,volblocksize,encryption,keystatus -p
capture "40-storage-zfs-snapshot-summary" bash -c 'zfs list -H -p -t snapshot -o name,used 2>/dev/null | awk -F "[\\t@]" "{count[\\$1]++; bytes[\\$1]+=\\$3} END {for (d in count) printf \\\"%s\\\\t%d\\\\t%.0f\\\\n\\\", d, count[d], bytes[d]}" | sort'
capture "40-storage-zfs-properties" zfs get -r -t filesystem,volume -s local,received all
capture "40-storage-btrfs-show" btrfs filesystem show --all-devices
capture "40-storage-btrfs-usage" bash -c 'while read -r m; do echo "== $m =="; btrfs filesystem usage -T -b "$m" 2>&1 || true; btrfs device stats "$m" 2>&1 || true; done < <(findmnt -rn -t btrfs -o TARGET)'
capture "40-storage-mergerfs-mounts" bash -c 'findmnt -rn -t fuse.mergerfs -o TARGET,SOURCE,OPTIONS; for m in $(findmnt -rn -t fuse.mergerfs -o TARGET); do echo "== $m branches =="; getfattr -n user.mergerfs.branches --only-values "$m/.mergerfs" 2>&1 || true; done'
capture "40-storage-snapraid-status" snapraid status
capture "40-storage-nvme-list" nvme list -o json
capture "40-storage-nvme-subsystems" nvme list-subsys -o json
if ((SKIP_SMART)); then
  echo "Skipped by --skip-smart." > "$OUT/40-storage-snapraid-smart.txt"
  echo "Skipped by --skip-smart." > "$OUT/40-storage-nvme-health.txt"
  echo "Skipped by --skip-smart." > "$OUT/40-storage-smart-scan.txt"
else
  capture "40-storage-snapraid-smart" snapraid smart
  capture "40-storage-nvme-health" bash -c 'for n in /dev/nvme[0-9]; do [[ -c "$n" ]] || continue; echo "== $n =="; nvme id-ctrl -o json "$n" 2>&1 || true; nvme smart-log -o json "$n" 2>&1 || true; nvme error-log -e 64 -o json "$n" 2>&1 || true; done'
  capture_timeout "40-storage-smart-scan" 600 bash -c '
    smartctl --scan 2>&1
    while read -r line; do
      [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
      read -r -a words <<< "$line"
      args=()
      for ((i=0; i<${#words[@]}; i++)); do
        [[ "${words[$i]}" == "#" ]] && break
        args+=("${words[$i]}")
      done
      ((${#args[@]})) || continue
      echo "== smartctl -n standby,3 -x ${args[*]} =="
      smartctl -n standby,3 -x "${args[@]}" 2>&1 || true
    done < <(smartctl --scan 2>/dev/null)
  '
fi

# Network topology and dual-10GbE feasibility evidence.
capture "50-network-ip-address" ip -details -json address show
capture "50-network-ip-link" ip -details -statistics -json link show
capture "50-network-routes" ip -details -json route show table all
capture "50-network-rules" ip -details -json rule show
capture "50-network-neighbors" ip -details -json neighbor show
capture "50-network-bridge-links" bridge -details -statistics -json link show
capture "50-network-bridge-vlans" bridge -details -statistics -json vlan show
capture "50-network-bridge-fdb" bridge -details -statistics -json fdb show
capture "50-network-networkctl" networkctl status --all --no-pager
capture "50-network-resolvectl" resolvectl status --no-pager
capture "50-network-ss" ss -H -lntup
capture "50-network-nftables" nft -a list ruleset
capture "50-network-iptables" iptables-save
capture "50-network-ip6tables" ip6tables-save
capture "50-network-forwarding" sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.ipv4.conf.all.rp_filter
capture "50-network-bonding" bash -c 'for f in /proc/net/bonding/*; do [[ -r "$f" ]] || continue; echo "== $f =="; cat "$f"; done'
capture "50-network-lldp" lldpcli show neighbors details
capture "50-network-devlink" devlink dev show
capture "50-network-devlink-info" bash -c 'for d in $(devlink dev show 2>/dev/null | cut -d: -f1-2); do echo "== $d =="; devlink dev info "$d" 2>&1 || true; done'
capture "50-network-rdma" rdma link show
capture "50-network-wireguard" wg show
capture "50-network-interface-details" bash -c '
  for p in /sys/class/net/*; do
    [[ -e "$p" ]] || continue
    i=${p##*/}
    [[ "$i" == lo ]] && continue
    echo "============================================================"
    echo "INTERFACE $i"
    echo "sysfs=$(readlink -f "$p/device" 2>/dev/null || true)"
    [[ -r "$p/address" ]] && printf "mac=" && cat "$p/address"
    [[ -r "$p/speed" ]] && printf "sysfs_speed_mbps=" && cat "$p/speed"
    [[ -r "$p/duplex" ]] && printf "duplex=" && cat "$p/duplex"
    ethtool "$i" 2>&1 || true
    ethtool -i "$i" 2>&1 || true
    ethtool -k "$i" 2>&1 || true
    ethtool -g "$i" 2>&1 || true
    ethtool -l "$i" 2>&1 || true
    ethtool -c "$i" 2>&1 || true
    ethtool -a "$i" 2>&1 || true
    ethtool -m "$i" 2>&1 || true
  done
'

# UPS visibility. upsc does not expose configured passwords.
capture "55-power-ups-list" upsc -l
capture "55-power-ups-status" bash -c 'for u in $(upsc -l 2>/dev/null); do echo "== $u =="; upsc "$u" 2>&1 || true; done'

# Role-specific state.
if [[ "$ROLE" == "hvn-hyp1" ]]; then
  capture "60-hvn-nixos-version" nixos-version --json
  capture "60-hvn-current-system" readlink -f /run/current-system
  capture "60-hvn-current-system-size" nix path-info -Sh /run/current-system
  capture "60-hvn-nix-channels" nix-channel --list
  capture "60-hvn-generation-list" nixos-rebuild list-generations --json
  capture "60-hvn-incus-info" incus info
  capture "60-hvn-incus-list" incus list --format json
  capture "60-hvn-libvirt-guests" virsh list --all
  capture "60-hvn-podman" podman info --format json
  capture "60-hvn-podman-containers" podman ps -a --size --format json
  capture "60-hvn-docker" docker info
  capture "60-hvn-docker-containers" docker ps -a --size --no-trunc
  capture "60-hvn-agenix-secret-names" bash -c 'if [[ -d /run/agenix ]]; then find /run/agenix -mindepth 1 -maxdepth 1 -printf "%f\n" | sort; fi'
  capture "60-hvn-gocryptfs-mounts" bash -c 'findmnt -rn -t fuse.gocryptfs -o TARGET,SOURCE,OPTIONS; journalctl -b --no-pager -u "gocryptfs-*" -n 500 2>&1 || true'
  add_default_scan_root /mnt/storage/media
else
  capture "60-proxmox-version" pveversion -v
  capture "60-proxmox-cluster-status" pvecm status
  capture "60-proxmox-cluster-nodes" pvecm nodes
  capture "60-proxmox-cluster-resources" pvesh get /cluster/resources --output-format json
  capture "60-proxmox-node-status" bash -c 'node=$(hostname -s); pvesh get "/nodes/$node/status" --output-format json'
  capture "60-proxmox-storage-status" pvesm status --content images,rootdir,backup,iso,vztmpl,snippets
  capture_existing_file "60-proxmox-storage-config" /etc/pve/storage.cfg
  capture_existing_file "60-proxmox-datacenter-config" /etc/pve/datacenter.cfg
  capture_existing_file "60-proxmox-corosync-config" /etc/pve/corosync.conf
  capture "60-proxmox-ha-status" ha-manager status
  capture "60-proxmox-ha-config" ha-manager config
  capture "60-proxmox-qm-list" qm list
  capture "60-proxmox-qm-configs" bash -c 'qm list 2>/dev/null | awk "NR>1 {print \$1}" | while read -r id; do echo "===== VM $id ====="; qm config "$id" --current 2>&1 || true; echo; done'
  capture "60-proxmox-pct-list" pct list
  capture "60-proxmox-pct-configs" bash -c 'pct list 2>/dev/null | awk "NR>1 {print \$1}" | while read -r id; do echo "===== CT $id ====="; pct config "$id" --current 2>&1 || true; echo; done'
  capture "60-proxmox-ceph-status" ceph status --format json-pretty
  capture "60-proxmox-ceph-osd-tree" ceph osd tree --format json-pretty
  capture "60-proxmox-package-state" dpkg-query -W -f='${binary:Package}\t${Version}\n'
  capture "60-proxmox-apt-sources" bash -c 'for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do [[ -r "$f" ]] || continue; echo "== $f =="; cat "$f"; done'
fi

# Common virtualization state detects what the old setup actually ran.
capture "65-virtualization-processes" ps -eo pid,ppid,user,group,comm,cgroup --sort=comm
capture "65-virtualization-kvm-modules" bash -c 'lsmod | grep -E "^(kvm|vfio|vhost|tun|bridge|bonding)" || true'
capture "65-virtualization-machinectl" machinectl list --all --no-pager

# Mount topology is always collected without recursively walking content.
capture "70-data-mount-capacity" findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS

if ((DEEP)); then
  if ((${#SCAN_ROOTS[@]} == 0)); then
    echo "Deep scan requested, but no conventional content root was found. Re-run with one or more --scan-root paths." >> "$WARNINGS"
  fi
  echo "Deep scans run sequentially at idle I/O priority. Each root gets one full metadata traversal; --include-paths adds one more." >> "$WARNINGS"

  for root in "${SCAN_ROOTS[@]}"; do
    if [[ ! -d "$root" ]]; then
      echo "Requested scan root is absent: $root" >> "$WARNINGS"
      continue
    fi
    root=$(readlink -f "$root")
    case "$root" in
      /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*)
        echo "Refusing unsafe or over-broad scan root: $root" >> "$WARNINGS"
        continue
        ;;
    esac
    id=$(printf '%s' "$root" | sha256sum | cut -c1-12)
    section="80-data-${id}"

    capture_deep_shell_timeout "${section}-summary" "$DEEP_TIMEOUT" '
      root=$1
      echo "root=$root"
      echo "filesystem:"
      findmnt -T "$root" -o TARGET,SOURCE,FSTYPE,OPTIONS,SIZE,USED,AVAIL,USE% -b
      echo
      now=$(date +%s)
      find "$root" -xdev -type f -printf "%s\t%T@\t%f\n" 2>/dev/null |
        awk -F "\t" -v now="$now" '\''
          {
            size=$1; mtime=$2; name=tolower($3);
            files++; total_bytes+=size;
            age=(now-mtime)/86400;
            if(age<1) age1++; else if(age<7) age7++; else if(age<30) age30++; else if(age<365) age365++; else ageold++;
            n=split(name,p,".");
            ext=(n>1 ? p[n] : "[no-extension]");
            if (length(ext)>16 || ext !~ /^[a-z0-9_+-]+$/) ext="[other]";
            ext_count[ext]++; ext_bytes[ext]+=size;
          }
          END {
            printf "aggregate_regular_files:\nfiles=%d\nbytes=%.0f\n\n", files, total_bytes;
            printf "mtime_buckets:\nlt_1_day=%d\n1_to_7_days=%d\n7_to_30_days=%d\n30_to_365_days=%d\nge_365_days=%d\n\n", age1, age7, age30, age365, ageold;
            print "extension_summary_bytes_and_files:";
            for (e in ext_count) printf "%s\t%d\t%.0f\n", e, ext_count[e], ext_bytes[e];
          }
        '\''
    ' "$root"

    if ((INCLUDE_PATHS)); then
      capture_deep_shell_timeout "${section}-paths" "$DEEP_TIMEOUT" '
        root=$1
        echo "root=$root"
        echo "# Directory sizes through depth 2 (bytes); this is a second full traversal."
        du -x -B1 --max-depth=2 "$root" 2>/dev/null | sort -n
      ' "$root"
    fi
  done
else
  cat >> "$WARNINGS" <<EOF
Deep content scanning was not requested. Re-run with --deep and explicit --scan-root paths to collect file counts, byte totals, extension mix, and modification-age distribution. Add --include-paths only if media titles/directory names may be included in the shared report.
EOF
fi

# Generate a compact tool-availability matrix to distinguish absent state from
# commands that were unavailable on a partially configured machine.
TOOLS=(
  smartctl nvme zpool zfs btrfs snapraid mergerfs cryptsetup mdadm pvs vgs lvs
  ethtool lldpcli devlink rdma wg ip bridge nft iptables-save
  dmidecode ipmitool sensors ras-mc-ctl vainfo ffmpeg
  nix nixos-version incus virsh podman docker
  pveversion pvecm pvesh pvesm qm pct ha-manager ceph
  upsc ionice nice
)
{
  printf 'tool\tpath\n'
  for tool in "${TOOLS[@]}"; do
    printf '%s\t%s\n' "$tool" "$(command -v "$tool" 2>/dev/null || printf MISSING)"
  done
} > "$OUT/90-tool-availability.tsv"

# Final checksums cover sanitized report files, not the archive itself.
find "$OUT" -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > "$OUT/SHA256SUMS"

ARCHIVE=""
if ((MAKE_ARCHIVE)); then
  ARCHIVE="${OUT}.tar.gz"
  tar -C "$OUTPUT_PARENT" -czf "$ARCHIVE" "${OUT##*/}"
fi

# Return ownership to the invoking sudo user when possible.
if [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]]; then
  chown -R "$SUDO_UID:$SUDO_GID" "$OUT"
  [[ -n "$ARCHIVE" ]] && chown "$SUDO_UID:$SUDO_GID" "$ARCHIVE"
fi

cat <<EOF

Phase 0 collection complete.
Report directory: $OUT
EOF
[[ -n "$ARCHIVE" ]] && echo "Archive:          $ARCHIVE"
cat <<'EOF'

Review 00-warnings.txt and 00-command-log.tsv. A nonzero command is often just
an unsupported or unconfigured subsystem; do not rerun destructive repair
commands. Inspect the archive before sharing because it contains sensitive
infrastructure metadata and, with --include-paths, content names.
EOF
