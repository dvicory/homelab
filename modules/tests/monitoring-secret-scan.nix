# Generated manifests and documentation may name monitoring credential files
# and Secrets, but never carry a credential value. Alertmanager's own fields
# are checked in monitoring-alertmanager; this catches a heartbeat URL, a
# Telegram bot token or a Grafana secret pasted anywhere in the output.
{ self, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks.monitoring-secret-scan =
        pkgs.runCommand "monitoring-secret-scan" { nativeBuildInputs = [ pkgs.gnugrep ]; }
          ''
            cd ${self}
            if grep -rnE \
              -e 'hc-ping\.com/[0-9A-Za-z_-]{8,}' \
              -e '\b[0-9]{6,12}:[A-Za-z0-9_-]{30,}\b' \
              -e '^\s*client_secret\s*=\s*[^$[:space:]]' \
              -e '^\s*admin_password\s*=\s*\S' \
              generated/manifests/prod-home docs/operations.md docs/operations; then
              echo "generated output above contains a monitoring credential value" >&2
              exit 1
            fi
            # Grafana's administrator password may come only from a Secret.
            if grep -rlPz 'GF_SECURITY_ADMIN_PASSWORD\n\s*value:' generated/manifests/prod-home; then
              echo "Grafana's administrator password is set inline" >&2
              exit 1
            fi
            touch $out
          '';
    };
}
