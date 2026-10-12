#!/usr/bin/env bash
# Jellyfin acceleration check (docs/operations/jellyfin.md, "Check hardware
# acceleration"). Run as root on the compute host. It reads state only and
# needs no playback.
#
#   sudo bash docs/operations/jellyfin-acceleration-check.sh [--transcode]
#
# --transcode also encodes five seconds of a generated 1080p test pattern
# with QSV inside the Jellyfin container and discards the output.
#
# Prints STATE (usable, degraded or software) and REASON. Exit status: 0 for
# usable or software by declaration, 1 for degraded, 2 when the check itself
# cannot run.
set -uo pipefail

project=${COMPUTE_PROJECT:-compute}
instance=${COMPUTE_INSTANCE:-compute-1}
node=/dev/dri/renderD128
ffmpeg_dir=/usr/lib/jellyfin-ffmpeg
transcode=false
case "${1:-}" in
  "") ;;
  --transcode) transcode=true ;;
  *) echo "usage: $0 [--transcode]" >&2; exit 2 ;;
esac

guest() { incus --project "$project" exec "$instance" --mode=non-interactive -- "$@"; }
kubectl() { guest k3s kubectl -n jellyfin "$@"; }
in_pod() { kubectl exec deployment/jellyfin -c jellyfin -- "$@"; }

host_facts() {
  echo "--- host facts"
  ls -l /dev/dri 2>&1
  if [ -e /sys/class/drm/renderD128/device ]; then
    echo "renderD128 device: $(basename "$(readlink -f /sys/class/drm/renderD128/device)")"
    echo "renderD128 driver: $(basename "$(readlink -f /sys/class/drm/renderD128/device/driver)")"
  fi
  systemctl status compute-accelerator-source.service --no-pager --lines=3 2>&1 | sed -n '1,8p'
  incus --project "$project" profile device show "$instance" 2>&1 | sed -n '/^gpu-render:/,/^[a-z]/p'
  echo "--- guest /dev/dri"
  guest ls -ln /dev/dri 2>&1
}

report() {
  echo "STATE: $1"
  echo "REASON: $2"
  if [ "$1" = degraded ]; then
    host_facts
    exit 1
  fi
  exit 0
}

configuration=$(kubectl get configmap jellarr-configuration -o 'jsonpath={.data.config\.yml}') || {
  echo "STATE: unknown"
  echo "REASON: cannot read the Jellarr configuration from the compute guest"
  exit 2
}
acceleration=$(printf '%s' "$configuration" | grep -o '"hardwareAccelerationType": *"[a-z0-9]*"' | grep -o '"[a-z0-9]*"$' | tr -d '"')
echo "DECLARED: hardwareAccelerationType=${acceleration:-unset}"
case "$acceleration" in
  none) report software "software transcoding is declared; the accelerator is not used" ;;
  qsv) ;;
  *) report degraded "the declared acceleration type is '${acceleration:-unset}', not qsv or none" ;;
esac

if ! in_pod test -c "$node" 2>/dev/null; then
  report degraded "$node is missing in the Jellyfin container; the host has no render node or Incus has not attached it"
fi
owner=$(in_pod stat -c '%g %a' "$node")
echo "NODE: $node group=${owner% *} mode=${owner#* }"
[ "$owner" = "506 660" ] || report degraded "$node is group ${owner% *}, mode ${owner#* }; the grant declares group 506 (gpu-render), mode 660"
in_pod id -G | tr ' ' '\n' | grep -qx 506 || report degraded "the Jellyfin process does not hold group 506 (gpu-render)"
in_pod sh -c "exec 3<>$node" 2>/dev/null || report degraded "the Jellyfin process cannot open $node"

vainfo=$(in_pod "$ffmpeg_dir/vainfo" --display drm --device "$node" 2>&1)
status=$?
driver=$(printf '%s\n' "$vainfo" | grep -m1 'Driver version' || true)
echo "VAINFO: ${driver:-no driver reported} (exit $status)"
if [ "$status" -ne 0 ] || ! printf '%s' "$vainfo" | grep -q 'iHD'; then
  report degraded "$node opens, but the Intel iHD VA-API driver did not initialize on it"
fi
printf '%s' "$vainfo" | grep -q 'VAEntrypointEncSlice' || report degraded "the iHD driver lists no hardware encode entry points"

if [ "$transcode" = true ]; then
  if ! in_pod "$ffmpeg_dir/ffmpeg" -hide_banner -loglevel error \
      -init_hw_device "vaapi=va:$node" -init_hw_device qsv=qs@va -filter_hw_device qs \
      -f lavfi -i testsrc2=duration=5:size=1920x1080:rate=30 \
      -vf 'format=nv12,hwupload=extra_hw_frames=64' -c:v h264_qsv -f null - ; then
    report degraded "a QSV test encode failed in the Jellyfin container"
  fi
  echo "TRANSCODE: QSV encoded a 5 s 1080p test pattern"
fi
report usable "Jellyfin opens $node and the iHD driver lists encode profiles"
