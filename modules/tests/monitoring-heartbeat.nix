# Heartbeat VM test with fake sources and fake receivers.
#
# The VM runs VictoriaMetrics, vmalert and Alertmanager from the same
# releases as the pinned images, with the rendered rule file and the
# rendered Alertmanager configuration. Test-only overrides shorten the
# scrape, evaluation, group and repeat intervals, lower VictoriaMetrics'
# free-space floor to fit a small filesystem, point the heartbeat URL file at
# a fake receiver, and replace the critical receiver with a second fake
# receiver. The Watchdog expression and the heartbeat receiver are used
# unchanged.
#
# Four small HTTP servers stand in for the core sources under their job
# names. The test shows:
# (a) healthy: pings arrive at the repeat interval;
# (b) stalled ingestion: with all four sources blocked by the firewall, the
#     query API, vmalert and Alertmanager keep answering, pings stop, and no
#     "resolved" request reaches the receiver;
# (c) read-only store: below the free-space floor VictoriaMetrics reports
#     read-only, queries still answer, and pings stop;
# (d) one stale source: pings continue, and the critical receiver gets
#     TelemetrySourceDown for it;
# (e) recovery: pings resume.
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
      fixturePython = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      fixtures =
        pkgs.runCommand "monitoring-heartbeat-fixtures"
          {
            nativeBuildInputs = [ fixturePython ];
          }
          ''
            mkdir "$out"
            python - ${rendered} "$out" <<'PY'
            import json, sys
            from pathlib import Path
            import yaml
            root, out = map(Path, sys.argv[1:])
            def data(name):
                return yaml.safe_load((root / "monitoring" / f"ConfigMap-{name}.yaml").read_text())["data"]
            rules = data("vmalert-rules")["rules.json"]
            alertmanager = data("alertmanager-config")
            (out / "rules.json").write_text(rules)
            (out / "homelab.tmpl").write_text(alertmanager["homelab.tmpl"])
            config = json.loads(alertmanager["alertmanager.yaml"])
            watchdog = next(r for g in json.loads(rules)["groups"] for r in g["rules"] if r.get("alert") == "Watchdog")
            heartbeat = next(r for r in config["receivers"] if r["name"] == "heartbeat")
            (out / "originals.json").write_text(json.dumps({"watchdog": watchdog, "heartbeat": heartbeat}))
            # Only repeat intervals and the critical test receiver differ.
            for route in config["route"]["routes"]:
                if route["receiver"] == "heartbeat":
                    route.update(group_interval="10s", repeat_interval="30s")
            config["receivers"] = [
                {"name": "critical", "webhook_configs": [{"url": "http://127.0.0.1:9002/critical"}]}
                if receiver["name"] == "critical" else receiver for receiver in config["receivers"]
            ]
            (out / "alertmanager.json").write_text(json.dumps(config))
            PY
          '';
      sources = {
        kubelet = {
          port = 9101;
          body = "kubelet_running_pods 5";
        };
        cadvisor = {
          port = 9102;
          body = "machine_cpu_cores 2";
        };
        kube-state-metrics = {
          port = 9103;
          body = ''kube_node_info{node="compute-1"} 1'';
        };
        host-node = {
          port = 9104;
          body = "node_time_seconds 1.8e9";
        };
      };
      scrape = {
        global = {
          scrape_interval = "10s";
          scrape_timeout = "5s";
        };
        scrape_configs =
          lib.mapAttrsToList (job: source: {
            job_name = job;
            static_configs = [
              {
                targets = [ "127.0.0.1:${toString source.port}" ];
                labels.host = "hvn-hyp1";
              }
            ];
          }) sources
          ++ [
            {
              job_name = "victoriametrics";
              static_configs = [ { targets = [ "127.0.0.1:8428" ]; } ];
            }
            {
              job_name = "alertmanager";
              static_configs = [ { targets = [ "127.0.0.1:9093" ]; } ];
            }
          ];
      };
      floorBytes = 120 * 1024 * 1024;
      fakeSource = pkgs.writeText "fake-source.py" ''
        import http.server, sys
        body = (sys.argv[2] + "\n").encode()
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; version=0.0.4")
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args):
                pass
        http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
      '';
      fakeReceiver = pkgs.writeText "fake-receiver.py" ''
        import http.server, json, sys, time
        log = sys.argv[2]
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
                with open(log, "a") as out:
                    out.write(json.dumps({"time": time.time(), "path": self.path, "body": body}) + "\n")
                self.send_response(200)
                self.end_headers()
            do_GET = do_POST
            def log_message(self, *args):
                pass
        http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
      '';
      python = lib.getExe pkgs.python3;
      test = pkgs.testers.runNixOSTest {
        name = "monitoring-heartbeat";
        requiredFeatures.kvm = true;
        nodes.machine =
          { pkgs, ... }:
          {
            system.stateVersion = "26.05";
            virtualisation.memorySize = 2048;
            networking.firewall.enable = true;
            environment.systemPackages = [
              pkgs.curl
              pkgs.iptables
            ];
            fileSystems."/var/lib/victoriametrics-test" = {
              fsType = "tmpfs";
              options = [ "size=300M" ];
            };
            environment.etc = {
              "victoriametrics/scrape.json".text = builtins.toJSON scrape;
              "vmalert/rules.json".source = "${fixtures}/rules.json";
              "alertmanager/config/alertmanager.yaml".source = "${fixtures}/alertmanager.json";
              "alertmanager/templates/homelab.tmpl".source = "${fixtures}/homelab.tmpl";
              "monitoring-originals.json".source = "${fixtures}/originals.json";
              # The heartbeat receiver reads its URL from this file.
              "alertmanager/delivery/heartbeat-url".text = "http://127.0.0.1:9001/ping\n";
            };
            systemd.services =
              lib.mapAttrs' (
                job: source:
                lib.nameValuePair "fake-${job}" {
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig.ExecStart = "${python} ${fakeSource} ${toString source.port} ${lib.escapeShellArg source.body}";
                }
              ) sources
              // {
                fake-heartbeat = {
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig.ExecStart = "${python} ${fakeReceiver} 9001 /tmp/heartbeat.log";
                };
                fake-critical = {
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig.ExecStart = "${python} ${fakeReceiver} 9002 /tmp/critical.log";
                };
                victoriametrics = {
                  wantedBy = [ "multi-user.target" ];
                  after = [ "var-lib-victoriametrics\\x2dtest.mount" ];
                  serviceConfig.ExecStart = lib.escapeShellArgs [
                    "${pkgs.victoriametrics}/bin/victoria-metrics"
                    "-storageDataPath=/var/lib/victoriametrics-test/data"
                    "-retentionPeriod=90d"
                    "-storage.minFreeDiskSpaceBytes=${toString floorBytes}"
                    "-promscrape.config=/etc/victoriametrics/scrape.json"
                    "-promscrape.config.strictParse=true"
                    "-httpListenAddr=127.0.0.1:8428"
                  ];
                };
                vmalert = {
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig = {
                    ExecStart = lib.escapeShellArgs [
                      "${pkgs.victoriametrics}/bin/vmalert"
                      "-datasource.url=http://127.0.0.1:8428"
                      "-remoteWrite.url=http://127.0.0.1:8428"
                      "-remoteRead.url=http://127.0.0.1:8428"
                      "-notifier.url=http://127.0.0.1:9093"
                      "-rule=/etc/vmalert/rules.json"
                      "-evaluationInterval=10s"
                      "-httpListenAddr=127.0.0.1:8880"
                    ];
                    Restart = "always";
                  };
                };
                alertmanager = {
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig = {
                    ExecStart = lib.escapeShellArgs [
                      "${pkgs.prometheus-alertmanager}/bin/alertmanager"
                      "--config.file=/etc/alertmanager/config/alertmanager.yaml"
                      "--storage.path=/var/lib/alertmanager-test"
                      "--web.listen-address=127.0.0.1:9093"
                      "--cluster.listen-address="
                    ];
                    StateDirectory = "alertmanager-test";
                  };
                };
              };
          };
        testScript = ''
          import json
          import time

          def pings():
              text = machine.succeed("cat /tmp/heartbeat.log 2>/dev/null || true")
              return [json.loads(line) for line in text.splitlines() if line]

          def ping_times():
              return [entry["time"] for entry in pings()]

          def diagnose():
              print(machine.execute("systemctl --no-pager status victoriametrics vmalert alertmanager fake-heartbeat | tail -60")[1])
              print(machine.execute("journalctl --no-pager -u vmalert -u alertmanager -u victoriametrics | tail -60")[1])
              print(machine.execute("curl -s http://127.0.0.1:8880/api/v1/alerts | head -c 3000")[1])
              print(machine.execute("curl -s 'http://127.0.0.1:8428/api/v1/query?query=up' | head -c 2000")[1])
              print(machine.execute("curl -s http://127.0.0.1:9093/api/v2/alerts | head -c 3000")[1])

          def wait_for_pings(count, timeout):
              deadline = time.time() + timeout
              start = len(pings())
              while time.time() < deadline:
                  if len(pings()) >= start + count:
                      return
                  time.sleep(5)
              diagnose()
              raise AssertionError(f"fewer than {count} new pings in {timeout} s")

          def assert_pings_stop(cause, bound):
              # Pings must stop within the expression's bound plus one repeat.
              started = float(machine.succeed("date +%s.%N"))
              time.sleep(bound)
              settled = len(pings())
              time.sleep(90)
              late = pings()[settled:]
              assert not late, f"{cause}: pings continued: {late}"
              stopped_at = max([t for t in ping_times() if t <= started + bound] or [started])
              print(f"EVIDENCE {cause}: last ping {stopped_at - started:.0f} s after the fault; none in the following {bound + 90 - (stopped_at - started):.0f} s")

          def no_resolved_pings():
              resolved = [entry for entry in pings() if '"status":"resolved"' in entry["body"].replace(" ", "")]
              assert not resolved, resolved

          start_all()
          for unit in ("victoriametrics", "vmalert", "alertmanager", "fake-heartbeat", "fake-critical"):
              machine.wait_for_unit(unit + ".service")
          machine.wait_for_open_port(8428)
          machine.wait_for_open_port(9093)

          with subtest("the rendered Watchdog and heartbeat receiver are in use unchanged"):
              originals = json.loads(machine.succeed("cat /etc/monitoring-originals.json"))
              rules = json.loads(machine.succeed("cat /etc/vmalert/rules.json"))
              watchdog = [r for g in rules["groups"] for r in g["rules"] if r.get("alert") == "Watchdog"]
              assert watchdog == [originals["watchdog"]], watchdog
              config = json.loads(machine.succeed("cat /etc/alertmanager/config/alertmanager.yaml"))
              heartbeat = [r for r in config["receivers"] if r["name"] == "heartbeat"]
              assert heartbeat == [originals["heartbeat"]], heartbeat

          with subtest("the pinned VictoriaMetrics exports the metrics the rules read"):
              metrics = machine.succeed("curl -sf http://127.0.0.1:8428/metrics")
              for name in ("vm_rows_added_to_storage_total", "vm_free_disk_space_bytes", "vm_data_size_bytes"):
                  assert f"\n{name}" in metrics, name
              print("EVIDENCE VictoriaMetrics exports vm_rows_added_to_storage_total, vm_free_disk_space_bytes, vm_data_size_bytes")

          with subtest("(a) healthy: pings arrive at the repeat interval"):
              wait_for_pings(3, 360)
              times = ping_times()[-3:]
              gaps = [b - a for a, b in zip(times, times[1:])]
              assert all(20 <= gap <= 75 for gap in gaps), gaps
              print(f"EVIDENCE healthy ping gaps {[round(g) for g in gaps]} s")

          with subtest("(b) stalled ingestion: pings stop while every service still answers"):
              machine.succeed("iptables -I OUTPUT -o lo -p tcp --dport 9101:9104 -j REJECT")
              assert_pings_stop("stalled ingestion", 240)
              machine.succeed("curl -sf 'http://127.0.0.1:8428/api/v1/query?query=up' >/dev/null")
              machine.succeed("curl -sf http://127.0.0.1:8880/api/v1/rules >/dev/null")
              machine.succeed("curl -sf http://127.0.0.1:9093/-/ready >/dev/null")
              no_resolved_pings()
              print("EVIDENCE stalled: query API, vmalert and Alertmanager answer; no resolved request reached the receiver")
              machine.succeed("iptables -D OUTPUT -o lo -p tcp --dport 9101:9104 -j REJECT")
              wait_for_pings(2, 360)

          with subtest("(c) read-only store: pings stop, queries still answer"):
              free = int(machine.succeed("df --output=avail -B1 /var/lib/victoriametrics-test | tail -1"))
              fill = free - ${toString floorBytes} + 30 * 1024 * 1024
              machine.succeed(f"fallocate -l {fill} /var/lib/victoriametrics-test/fill")
              machine.wait_until_succeeds("curl -sf http://127.0.0.1:8428/metrics | grep -q '^vm_storage_is_read_only{.*} 1$'", timeout=120)
              assert_pings_stop("read-only store", 240)
              machine.succeed("curl -sf 'http://127.0.0.1:8428/api/v1/query?query=up' >/dev/null")
              no_resolved_pings()
              print("EVIDENCE read-only: vm_storage_is_read_only 1; queries answer")
              machine.succeed("rm /var/lib/victoriametrics-test/fill")
              machine.wait_until_succeeds("curl -sf http://127.0.0.1:8428/metrics | grep -q '^vm_storage_is_read_only{.*} 0$'", timeout=120)
              wait_for_pings(2, 360)

          with subtest("(d) one stale source: pings continue, the critical receiver gets TelemetrySourceDown"):
              # Earlier faults also fired TelemetrySourceDown for kubelet; wait
              # until it has resolved, then count only notices sent after the stop.
              machine.wait_until_succeeds(
                  "curl -sf 'http://127.0.0.1:9093/api/v2/alerts?active=true&filter=alertname%3D%22TelemetrySourceDown%22&filter=job%3D%22kubelet%22' | grep -qx '\\[\\]'",
                  timeout=300,
              )
              machine.succeed("systemctl stop fake-kubelet.service")
              stopped = float(machine.succeed("date +%s.%N"))
              def kubelet_down():
                  text = machine.succeed("cat /tmp/critical.log 2>/dev/null || true")
                  for line in text.splitlines():
                      entry = json.loads(line)
                      if entry["time"] < stopped:
                          continue
                      body = json.loads(entry["body"])
                      for alert in body["alerts"]:
                          labels = alert["labels"]
                          if labels.get("alertname") == "TelemetrySourceDown" and labels.get("job") == "kubelet" and alert["status"] == "firing":
                              return True
                  return False
              deadline = time.time() + 600
              while not kubelet_down():
                  assert time.time() < deadline, "TelemetrySourceDown for kubelet did not reach the critical receiver"
                  time.sleep(10)
              arrived = float(machine.succeed("date +%s.%N"))
              print(f"EVIDENCE TelemetrySourceDown(kubelet) reached the critical receiver within {arrived - stopped:.0f} s of the source stopping")
              wait_for_pings(2, 120)
              print("EVIDENCE pings continued with one core source stale")

          with subtest("(e) recovery: pings resume"):
              machine.succeed("systemctl start fake-kubelet.service")
              wait_for_pings(2, 120)
              no_resolved_pings()
              print(f"EVIDENCE {len(pings())} pings in total; none was a resolved message")
        '';
      };
    in
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        monitoring-heartbeat = test // {
          meta = test.meta // {
            hestia.group = "${system}-monitoring-heartbeat-runtime";
          };
        };
      };
    };
}
