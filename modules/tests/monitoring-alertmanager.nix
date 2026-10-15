# Checks for the rendered prod-home Alertmanager configuration, run with the
# Alertmanager release that the image pins:
# - `amtool check-config` accepts it, and `amtool config routes test` pins
#   the current routing;
# - the fleet-monitoring delivery floor holds for any routing: every critical
#   alert reaches both channels at a Pushover priority that bypasses quiet
#   hours, every warning reaches at least one channel, resolutions are sent,
#   each failing channel is reported through the other, the heartbeat never
#   sends a resolved message, and credentials appear only as file paths;
# - with no credential files at all, Alertmanager keeps running and counts
#   failed notifications for every integration instead of crashing or using
#   a placeholder, and the inhibition rules hide what they should.
{
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      # Native rendering remains covered by prod-home-manifests-fresh.
      rendered = ../../generated/manifests/prod-home;
      routeCases = [
        {
          receiver = "critical";
          labels = "alertname=HostZpoolUnhealthy severity=critical host=hvn-hyp1";
        }
        {
          receiver = "warning";
          labels = "alertname=KubeJobFailed severity=warning namespace=media";
        }
        {
          receiver = "heartbeat";
          labels = "alertname=Watchdog severity=none";
        }
        {
          receiver = "telegram-only";
          labels = "alertname=AlertDeliveryFailing integration=pushover severity=critical";
        }
        {
          receiver = "pushover-only";
          labels = "alertname=AlertDeliveryFailing integration=telegram severity=critical";
        }
      ];
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.monitoring-alertmanager =
        pkgs.runCommand "monitoring-alertmanager"
          {
            __darwinAllowLocalNetworking = true;
            nativeBuildInputs = [
              pkgs.prometheus-alertmanager
              pkgs.curl
              python
            ];
          }
          ''
            set -euo pipefail
            mkdir templates
            python - ${rendered} <<'PY'
            from pathlib import Path
            import sys, yaml
            obj = yaml.safe_load((Path(sys.argv[1]) / "monitoring/ConfigMap-alertmanager-config.yaml").read_text())
            Path("rendered-alertmanager.json").write_text(obj["data"]["alertmanager.yaml"])
            Path("templates/homelab.tmpl").write_text(obj["data"]["homelab.tmpl"])
            PY
            # The only change: templates load from here instead of the pod path.
            ${python.interpreter} - rendered-alertmanager.json > alertmanager.json <<'PY'
            import json, sys
            config = json.load(open(sys.argv[1]))
            assert config["templates"] == ["/etc/alertmanager/templates/*.tmpl"], config["templates"]
            config["templates"] = ["templates/*.tmpl"]
            json.dump(config, sys.stdout)
            PY
            amtool check-config alertmanager.json

            ${lib.concatMapStringsSep "\n" (case: ''
              amtool config routes test --config.file=alertmanager.json \
                --verify.receivers=${case.receiver} ${case.labels}
            '') routeCases}

            ${python.interpreter} - alertmanager.json <<'PY'
            import json, sys
            config = json.load(open(sys.argv[1]))
            receivers = {r["name"]: r for r in config["receivers"]}
            # Fields that would carry a credential inline. Pushover's `url`
            # is the Grafana link shown with the message, not a credential.
            credential_fields = {
                "pushover_configs": {"user_key", "token"},
                "telegram_configs": {"bot_token", "chat_id"},
                "webhook_configs": {"url"},
            }

            def channels(name):
                receiver = receivers[name]
                return {kind: receiver.get(f"{kind}_configs", []) for kind in ("pushover", "telegram")}

            # Spec floor: critical on both channels, past quiet hours.
            critical = channels("critical")
            assert critical["pushover"] and critical["telegram"], critical
            assert all(int(c["priority"]) >= 1 for c in critical["pushover"]), critical
            # Spec floor: a warning reaches at least one channel.
            warning = channels("warning")
            assert warning["pushover"] or warning["telegram"], warning
            # Spec floor: resolutions are sent on every owner-facing channel.
            for name in ("critical", "warning", "telegram-only", "pushover-only"):
                for kind, configs in channels(name).items():
                    for c in configs:
                        assert c.get("send_resolved") is True, (name, kind)
            # Each failing channel is reported through the other one.
            assert channels("telegram-only") == {"pushover": [], "telegram": channels("telegram-only")["telegram"]}
            assert channels("telegram-only")["telegram"]
            assert channels("pushover-only")["pushover"] and not channels("pushover-only")["telegram"]
            assert all(int(c["priority"]) >= 1 for c in channels("pushover-only")["pushover"])

            # A resolved message to the ping URL would count as one more ping.
            heartbeat = receivers["heartbeat"]["webhook_configs"]
            assert heartbeat and all(c["send_resolved"] is False for c in heartbeat), heartbeat

            # Credentials only as files.
            for receiver in config["receivers"]:
                for key, configs in receiver.items():
                    if not key.endswith("_configs"):
                        continue
                    for c in configs:
                        inline = credential_fields[key] & set(c)
                        assert not inline, (receiver["name"], key, inline)
                        assert any(k.endswith("_file") for k in c), (receiver["name"], key)
            print("alertmanager routing: the delivery floor holds")
            PY

            # Run it with no credential files at all.
            mkdir storage
            alertmanager --config.file=alertmanager.json --storage.path=storage \
              --web.listen-address=127.0.0.1:19093 --cluster.listen-address= \
              --log.level=info > alertmanager.log 2>&1 &
            pid=$!
            url=http://127.0.0.1:19093
            for _ in $(seq 1 60); do
              curl -sf $url/-/ready >/dev/null && break
              sleep 0.5
            done
            curl -sf $url/-/ready >/dev/null

            post() {
              curl -sf -XPOST -H 'Content-Type: application/json' $url/api/v2/alerts -d "$1" >/dev/null
            }
            post '[
              {"labels":{"alertname":"Watchdog","severity":"none"}},
              {"labels":{"alertname":"HostZpoolUnhealthy","severity":"critical","host":"hvn-hyp1","pool":"rpool"}},
              {"labels":{"alertname":"KubeJobFailed","severity":"warning","namespace":"media","job_name":"x"}},
              {"labels":{"alertname":"TelemetrySourceDown","severity":"critical","job":"host-node","host":"hvn-hyp1"}},
              {"labels":{"alertname":"HostZpoolStatusStale","severity":"critical","host":"hvn-hyp1"}},
              {"labels":{"alertname":"HostDiskTelemetryMissing","severity":"critical","host":"hvn-hyp1","disk":"media4"}},
              {"labels":{"alertname":"HostZpoolMissing","severity":"critical","host":"hvn-hyp1","pool":"rpool"}},
              {"labels":{"alertname":"KubePodCrashLooping","severity":"critical","namespace":"jellyfin","pod":"p","container":"c"}},
              {"labels":{"alertname":"KubePodNotReady","severity":"critical","namespace":"jellyfin","pod":"p"}},
              {"labels":{"alertname":"HostFilesystemLowSpace","severity":"critical","host":"hvn-hyp1","mountpoint":"/persist"}},
              {"labels":{"alertname":"HostFilesystemLowSpace","severity":"warning","host":"hvn-hyp1","mountpoint":"/persist"}}
            ]'

            # group_wait is 30 s. Telegram retries a missing file until the
            # group interval (2 minutes) ends, then counts the failure.
            # Direct input avoids grep -q closing a producer pipe under pipefail.
            for _ in $(seq 1 300); do
              metrics="$(curl -sf $url/metrics)"
              if grep -Eq '^alertmanager_notifications_failed_total\{[^}]*integration="pushover"[^}]*\} [1-9]' <<< "$metrics" &&
                grep -Eq '^alertmanager_notifications_failed_total\{[^}]*integration="telegram"[^}]*\} [1-9]' <<< "$metrics" &&
                grep -Eq '^alertmanager_notifications_failed_total\{[^}]*integration="webhook"[^}]*\} [1-9]' <<< "$metrics"; then
                break
              fi
              sleep 1
            done
            printf '%s\n' "$metrics" | grep '^alertmanager_notifications_failed_total' | grep -v ' 0$'
            grep -Eq '^alertmanager_notifications_failed_total\{[^}]*integration="pushover"[^}]*\} [1-9]' <<< "$metrics"
            grep -Eq '^alertmanager_notifications_failed_total\{[^}]*integration="telegram"[^}]*\} [1-9]' <<< "$metrics"
            grep -Eq '^alertmanager_notifications_failed_total\{[^}]*integration="webhook"[^}]*\} [1-9]' <<< "$metrics"
            kill -0 $pid
            grep -q 'read token_file' alertmanager.log
            grep -q 'heartbeat-url' alertmanager.log

            curl -sf $url/api/v2/alerts > alerts.json
            ${python.interpreter} - alerts.json <<'PY'
            import json, sys
            alerts = json.load(open(sys.argv[1]))
            def inhibited(**labels):
                for alert in alerts:
                    if all(alert["labels"].get(k) == v for k, v in labels.items()):
                        return bool(alert["status"]["inhibitedBy"])
                raise AssertionError(f"alert {labels} not found")
            # A silent host exporter hides the stale-file and missing-item alerts.
            assert inhibited(alertname="HostZpoolStatusStale")
            assert inhibited(alertname="HostDiskTelemetryMissing")
            assert inhibited(alertname="HostZpoolMissing")
            assert not inhibited(alertname="TelemetrySourceDown")
            # A crash loop hides not-ready for the same pod.
            assert inhibited(alertname="KubePodNotReady")
            # Critical hides the warning for the same object.
            assert inhibited(alertname="HostFilesystemLowSpace", severity="warning")
            assert not inhibited(alertname="HostFilesystemLowSpace", severity="critical")
            assert not inhibited(alertname="HostZpoolUnhealthy")
            print("alertmanager inhibition holds")
            PY
            kill $pid
            touch $out
          '';
    };
}
