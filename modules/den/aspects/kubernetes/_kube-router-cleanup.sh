# Remove what K3s's embedded network-policy controller (kube-router) leaves
# behind once K3s runs with disable-network-policy (k3s-io/k3s#7244).
# Run as root inside the compute guest:
#   incus --project compute exec compute-1 -- sh -s < _kube-router-cleanup.sh
# Each restore rewrites only the filter table, without kube-router's chains,
# in one batch. Safe to repeat; fails if any kube-router rule remains.
set -eu
# K3s's own iptables and ipset tools.
PATH=$(tr '\0' '\n' < "/proc/$(systemctl show -p MainPID --value k3s)/environ" | sed -n 's/^PATH=//p'):$PATH
pattern='KUBE-ROUTER|KUBE-POD-FW-|KUBE-NWPLCY-'
for family in iptables ip6tables; do
  "$family-save" -t filter | grep -v -E "$pattern" | "$family-restore" -w -T filter
done
ipset list -n | grep -E '^(inet6:)?(KUBE-SRC-|KUBE-DST-|kube-router-)' | xargs -r -n 1 ipset destroy
left=$( (iptables-save; ip6tables-save) | grep -c -E "$pattern" || true)
echo "kube-router rules left: $left"
[ "$left" -eq 0 ]
