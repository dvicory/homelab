# Classify retained Jellyfin state before Provision mode can write to it.
#
# Jellyfin decides fresh versus initialized state from one field:
# IsStartupWizardCompleted in $JELLYFIN_CONFIG_DIR/system.xml. Patched
# Provision mode does nothing when it is true. Provisioning is not
# transactional, so anything else that is not empty is partial state left by
# an earlier failed run. Refuse it instead of provisioning over it.
data_dir="${JELLYFIN_DATA_DIR:?JELLYFIN_DATA_DIR is not set}"
system_xml="${JELLYFIN_CONFIG_DIR:?JELLYFIN_CONFIG_DIR is not set}/system.xml"

if [ ! -d "$data_dir" ]; then
  echo "jellyfin-provision: $data_dir is not a directory" >&2
  exit 1
fi

shopt -s dotglob nullglob
entries=("$data_dir"/*)
shopt -u dotglob nullglob

if [ "${#entries[@]}" -eq 0 ]; then
  echo "jellyfin-provision: $data_dir is empty; provisioning fresh state"
  exit 0
fi

if [ -f "$system_xml" ] &&
  grep -Eq '<IsStartupWizardCompleted>[[:space:]]*true[[:space:]]*</IsStartupWizardCompleted>' "$system_xml"; then
  echo "jellyfin-provision: $data_dir is initialized; Provision mode leaves it unchanged"
  exit 0
fi

echo "jellyfin-provision: refusing partial provisioning state in $data_dir:" \
  "it is not empty and Jellyfin setup is not complete." \
  "An earlier provisioning run failed after preflight." \
  "Inspect $data_dir, then restore it from a backup or clear it." >&2
exit 1
