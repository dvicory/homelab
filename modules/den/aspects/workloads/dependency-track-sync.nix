{
  den,
  config,
  lib,
  inputs,
  ...
}:
let
  rootConfig = config;
in
{
  den.aspects.workloads.dependency-track-sync = {
    # Explicit paired selection; private bootstrap can omit the ingestor credentials
    # and schedule while the independent root access-policy controller admits it.
    compute-guest.includes = [ den.aspects.workloads.dependency-track-sync ];
    settings = {
      apiUrl = lib.mkOption {
        type = lib.types.str;
        description = "Supported private Dependency-Track API URL; this does not establish a listener or grant network access.";
      };
      repository = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+";
        default = "dvicory/homelab";
        description = "Explicit trusted public producer repository; only its vulnerability-management workflow data is admitted.";
      };
      branch = lib.mkOption {
        type = lib.types.str;
        default = "main";
        description = "Trusted source branch, persisted separately from adjustable selection. Canaries require separate API/evidence state.";
      };
      targetIds = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[a-f0-9]{24}");
        default = [ ];
        description = "Explicit declaration IDs overriding state selection. Empty follows sourceStates; excluded data remains active and journaled.";
      };
      sourceStates = lib.mkOption {
        type = lib.types.addCheck (lib.types.listOf (
          lib.types.enum [
            "desired"
            "referenced"
            "exported"
          ]
        )) (states: states != [ ]);
        default = [
          "desired"
          "referenced"
        ];
        description = "Declared desired/reference scope, never deployment. Add exported explicitly for the catalogue; unsupported/excluded coverage remains accounted.";
      };
      maxAgeSeconds = lib.mkOption {
        type = lib.types.ints.between 1 7776000;
        default = 604800;
        description = "Maximum completed producer-run age; stale acquisition fails without replacing last-good.";
      };
      stateDirectory = lib.mkOption {
        type = lib.types.strMatching "/.*";
        default = "/var/lib/dependency-track-sync";
        description = "Durable canonical originals/provenance and single-writer lifecycle journal, separately persisted on a base host. The compute-guest variant fixes this to the existing /srv/state/dependency-track-evidence retained mount.";
      };
      onCalendar = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "daily";
        description = "Automatic refresh schedule for this opt-in workload; null installs an explicitly started oneshot only.";
      };
    };
    persist =
      { host, ... }:
      lib.optionals (!(host.hasAspect den.aspects.workloads.dependency-track-sync.compute-guest)) [
        {
          directories = [ host.settings.workloads.dependency-track-sync.stateDirectory ];
          user = "dependency-track-sync";
          group = "dependency-track-sync";
          mode = "0700";
        }
      ];
    nixos =
      {
        host,
        config,
        pkgs,
        ...
      }:
      let
        cfg = host.settings.workloads.dependency-track-sync;
        name = "dependency-track-sync";
        package = pkgs.callPackage (inputs.self + "/pkgs/by-name/dependency-track-sync/package.nix") { };
        computeGuest = host.hasAspect den.aspects.workloads.dependency-track-sync.compute-guest;
        pairedClusters = lib.filterAttrs (
          clusterName: cluster:
          cluster.hostSystem == pkgs.stdenv.hostPlatform.system
          &&
            rootConfig.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute.instance
            == host.name
        ) rootConfig.den.clusters;
        selectedClusters = lib.filterAttrs (
          clusterName: cluster:
          rootConfig.flake.nixidyEnvs.${cluster.hostSystem}.${clusterName}.config.applications
          ? dependency-track
        ) pairedClusters;
        requestedPrivateAccess = lib.any (
          cluster: cluster.settings.kubernetes.services.dependency-track.privateAccess or false
        ) (builtins.attrValues pairedClusters);
        privateAccess = computeGuest && requestedPrivateAccess;
        policyRuntime = "/run/dependency-track-access-policy";
        brokerRuntime = "/run/dependency-track-sync-api-tunnel";
        stateDirectory =
          if computeGuest then "/srv/state/dependency-track-evidence" else cfg.stateDirectory;
        # Reserve the listener against impersonation by unprivileged guest processes.
        apiPort = 1022;
        unprivilegedPortStart = config.boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" or null;
        allowedNixUsers = config.nix.settings.allowed-users or [ "*" ];
        credentialDirectory = "/run/dependency-track-sync-credentials";
        apiKeyPath =
          if computeGuest then
            "${credentialDirectory}/api-key"
          else
            config.age.secrets.dependency-track-sync-api-key.path;
        githubTokenPath =
          if computeGuest then
            "${credentialDirectory}/github-token"
          else
            config.age.secrets.dependency-track-sync-github-token.path;
        kubectlExe = lib.getExe' config.services.k3s.package.k3sBundle "kubectl";
        kubectl = "${kubectlExe} --namespace dependency-track";
        stageCredentials = pkgs.writeShellScript "dependency-track-sync-credentials" ''
          set -euo pipefail
          test -s /srv/secrets/runtime-secrets.commit
          ${kubectl} --cache-dir=${credentialDirectory}/kube-cache --request-timeout=30s get secret dependency-track-sync -o json 2>/dev/null \
            | ${pkgs.python3}/bin/python3 -c ${lib.escapeShellArg ''
              import base64, json, os
              from pathlib import Path
              import sys, tempfile
              try:
                  secret = json.load(sys.stdin)
                  if (secret["metadata"]["namespace"] != "dependency-track"
                          or secret["metadata"]["name"] != "dependency-track-sync"):
                      raise ValueError()
                  values = {}
                  for name in ("api-key", "github-token"):
                      value = base64.b64decode(secret["data"][name], validate=True)
                      text = value.decode().strip()
                      if not 0 < len(value) <= 65536 or not text or "\n" in text or "\r" in text:
                          raise ValueError()
                      values[name] = value
                  root = Path("${credentialDirectory}")
                  for name, value in values.items():
                      descriptor, filename = tempfile.mkstemp(dir=root)
                      temporary = Path(filename)
                      try:
                          with os.fdopen(descriptor, "wb") as output:
                              output.write(value)
                              output.flush()
                              os.fsync(output.fileno())
                          temporary.chmod(0o400)
                          os.replace(temporary, root / name)
                      finally:
                          temporary.unlink(missing_ok=True)
              except Exception:
                  print("Dependency-Track credential projection failed", file=sys.stderr)
                  sys.exit(1)
            ''}
        '';
        requireReservedPort = pkgs.writeShellScript "dependency-track-sync-reserved-port" ''
          set -eu
          read -r boundary < /proc/sys/net/ipv4/ip_unprivileged_port_start
          if ! test "$boundary" -gt ${toString apiPort}; then
            echo "Dependency-Track private transport requires reserved TCP port ${toString apiPort}" >&2
            exit 1
          fi
        '';
        waitForApi = pkgs.writeShellScript "dependency-track-sync-api-ready" ''
          exec ${pkgs.python3}/bin/python3 -c ${lib.escapeShellArg ''
            from http.client import HTTPConnection
            import sys, time
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                connection = HTTPConnection("127.0.0.1", ${toString apiPort}, timeout=min(2, deadline - time.monotonic()))
                try:
                    connection.request("GET", "/api/version")
                    if connection.getresponse().status == 200:
                        sys.exit(0)
                except OSError:
                    pass
                finally:
                    connection.close()
                time.sleep(min(1, max(0, deadline - time.monotonic())))
            print("Dependency-Track loopback transport readiness deadline exceeded", file=sys.stderr)
            sys.exit(1)
          ''}
        '';
        accessPolicyProgram = pkgs.writeText "dependency-track-access-policy.py" ''
          import base64
          from datetime import datetime, timezone
          import json
          import os
          from pathlib import Path
          import re
          import signal
          import subprocess
          import sys
          import time
          import uuid

          namespace = "dependency-track"
          condition_type = "security.homelab/access-policy-ready"
          runtime = Path(os.environ["RUNTIME_DIRECTORY"])
          broker_record = Path("${brokerRuntime}/pod.json")
          deadline = time.monotonic() + 240
          os.umask(0o077)
          if os.geteuid() != 0:
              sys.exit("Dependency-Track policy requires root")
          home = runtime if sys.argv[1] == "reconcile" else broker_record.parent
          if (home.is_symlink() or not home.is_dir() or home.stat().st_uid != 0
                  or home.stat().st_mode & 0o777 != 0o700):
              sys.exit("Dependency-Track policy requires a private root runtime directory")
          os.environ["HOME"] = str(home)
          os.environ["XDG_CACHE_HOME"] = str(home / "cache")
          (home / "cache").mkdir(mode=0o700, exist_ok=True)
          kubectl = ["${kubectlExe}", "--namespace", namespace,
                     "--cache-dir=" + str(home / "cache"), "--request-timeout=10s"]

          def run(arguments, *, data=None, timeout=10):
              process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL)
              try:
                  output, _ = process.communicate(
                      data, timeout=max(0.1, min(timeout, deadline - time.monotonic())))
              except BaseException:
                  try:
                      process.terminate()
                  except ProcessLookupError:
                      pass
                  try:
                      process.communicate(timeout=15)
                  except subprocess.TimeoutExpired:
                      process.kill()
                      process.communicate()
                  raise
              if process.returncode:
                  raise subprocess.CalledProcessError(process.returncode, arguments)
              return subprocess.CompletedProcess(arguments, process.returncode, output)

          def get(kind, name=None, selector=None):
              arguments = kubectl + ["get", kind]
              if name:
                  arguments.append(name)
              if selector:
                  arguments += ["--selector", selector]
              resource = json.loads(run(arguments + ["-o", "json"]).stdout)
              if name and (resource["metadata"]["name"] != name
                           or resource["metadata"]["namespace"] != namespace
                           or resource["metadata"].get("deletionTimestamp")):
                  raise ValueError()
              return resource

          def owned(resource, kind, uid):
              return any(owner.get("controller") is True and owner.get("kind") == kind
                         and owner.get("uid") == uid
                         for owner in resource["metadata"].get("ownerReferences", []))

          def current_pods():
              deployment = get("deployment", "dependency-track-api")
              metadata = deployment["metadata"]
              if metadata.get("deletionTimestamp"):
                  raise ValueError()
              selector = "app.kubernetes.io/name=dependency-track-api"
              replicasets = get("replicasets", selector=selector)["items"]
              replica_uids = {replica["metadata"]["uid"] for replica in replicasets
                              if owned(replica, "Deployment", metadata["uid"])
                              and not replica["metadata"].get("deletionTimestamp")}
              pods = [pod for pod in get("pods", selector=selector)["items"]
                      if pod["metadata"]["namespace"] == namespace
                      and not pod["metadata"].get("deletionTimestamp")
                      and pod.get("status", {}).get("phase") == "Running"
                      and any(owned(pod, "ReplicaSet", uid) for uid in replica_uids)]
              return deployment, pods

          def select():
              deployment, pods = current_pods()
              if (deployment["spec"].get("replicas") != 1
                      or deployment["spec"]["strategy"]["type"] != "Recreate"
                      or deployment["spec"]["selector"]["matchLabels"]
                         != {"app.kubernetes.io/name": "dependency-track-api"}
                      or len(pods) != 1):
                  raise ValueError()
              pod = pods[0]
              if (not any(gate.get("conditionType") == condition_type
                          for gate in pod["spec"].get("readinessGates", []))
                      or [container["name"] for container in pod["spec"]["containers"]] != ["api"]):
                  raise ValueError()
              return deployment, pod

          def identity(deployment, pod):
              return {"deploymentUID": deployment["metadata"]["uid"],
                      "podUID": pod["metadata"]["uid"], "podName": pod["metadata"]["name"]}

          def set_condition(pod, admitted):
              uid = pod["metadata"]["uid"]
              while time.monotonic() < deadline:
                  conditions = pod.get("status", {}).get("conditions", [])
                  indices = [index for index, item in enumerate(conditions)
                             if item["type"] == condition_type]
                  if len(indices) > 1:
                      raise ValueError()
                  status = "True" if admitted else "False"
                  if indices and conditions[indices[0]]["status"] == status:
                      return
                  condition = {"type": condition_type, "status": status,
                               "reason": "AccessPolicyVerified" if admitted else "AccessPolicyUnverified",
                               "message": "Root access-policy reconciliation " + ("succeeded" if admitted else "failed"),
                               "lastTransitionTime": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")}
                  patch = [{"op": "test", "path": "/metadata/uid", "value": uid},
                           {"op": "test", "path": "/metadata/resourceVersion",
                            "value": pod["metadata"]["resourceVersion"]}]
                  if indices:
                      patch.append({"op": "replace", "path": "/status/conditions/" + str(indices[0]),
                                    "value": condition})
                  elif "conditions" in pod.get("status", {}):
                      patch.append({"op": "add", "path": "/status/conditions/-", "value": condition})
                  else:
                      patch.append({"op": "add", "path": "/status/conditions", "value": [condition]})
                  try:
                      run(kubectl + ["patch", "pod", pod["metadata"]["name"], "--subresource=status",
                                     "--type=json", "--patch-file=/dev/stdin"],
                          data=json.dumps(patch).encode())
                      return
                  except subprocess.CalledProcessError:
                      current = get("pod", pod["metadata"]["name"])
                      if current["metadata"]["uid"] != uid:
                          raise ValueError()
                      if current["metadata"]["resourceVersion"] == pod["metadata"]["resourceVersion"]:
                          raise
                      pod = current
              raise TimeoutError()

          def desired():
              configmap = get("configmap", "dependency-track-access-policy")
              if set(configmap.get("data", {})) != {"policy.json"}:
                  raise ValueError()
              policy = json.loads(configmap["data"]["policy.json"])
              if (set(policy) != {"schema", "bootstrap", "oidcGroup"}
                      or type(policy["schema"]) is not int or policy["schema"] != 1
                      or type(policy["bootstrap"]) is not bool
                      or not isinstance(policy["oidcGroup"], str)
                      or not 1 <= len(policy["oidcGroup"]) <= 255
                      or not policy["oidcGroup"].strip()
                      or any(ord(char) < 32 or 127 <= ord(char) <= 159
                             for char in policy["oidcGroup"])):
                  raise ValueError()
              return configmap, policy

          def validate_result(raw, group):
              if len(raw) > 65536:
                  raise ValueError()
              result = json.loads(raw)
              if (set(result) != {"schema", "oidcGroup", "administratorTeam",
                                 "defaultLoginRefusal", "advisoryPolicy"}
                      or type(result["schema"]) is not int or result["schema"] != 1
                      or result["defaultLoginRefusal"] != "INVALID_CREDENTIALS"
                      or set(result["oidcGroup"]) != {"name", "uuid"}
                      or result["oidcGroup"]["name"] != group
                      or set(result["administratorTeam"]) != {"name", "uuid", "permissions"}
                      or result["administratorTeam"]["name"] != "Administrators"):
                  raise ValueError()
              for item in (result["oidcGroup"], result["administratorTeam"]):
                  if str(uuid.UUID(item["uuid"])) != item["uuid"]:
                      raise ValueError()
              permissions = result["administratorTeam"]["permissions"]
              if (not isinstance(permissions, list) or not permissions
                      or any(not isinstance(item, str) or not re.fullmatch(r"[A-Z_]+", item)
                             for item in permissions)
                      or permissions != sorted(set(permissions))):
                  raise ValueError()
              source = json.loads(Path("${package}/lib/dependency-track-sync/advisory-policy.json").read_text())
              if result["advisoryPolicy"] != {
                  "advisorySources": {name: {"enabled": value["enabled"],
                                           "ecosystems": value.get("ecosystems", [])}
                                      for name, value in source.items()},
                  "coverage": "Enabled sources do not prove completed mirrors, Nix patch applicability, runtime use or a clean scan."
              }:
                  raise ValueError()

          def reconcile():
              deployment, pod = select()
              expected = identity(deployment, pod)
              if json.loads(broker_record.read_text()) != expected:
                  raise ValueError()
              configmap, policy = desired()
              secret = get("secret", "dependency-track-admin")
              password = base64.b64decode(secret["data"]["password"], validate=True)
              if not 0 < len(password) <= 65536:
                  raise ValueError()
              password_file = runtime / "admin-password"
              with password_file.open("xb") as output:
                  os.fchmod(output.fileno(), 0o400)
                  output.write(password)
              arguments = ["${package}/bin/dependency-track-sync", "configure-access",
                           "--api-url", "http://127.0.0.1:${toString apiPort}",
                           "--admin-password-file", str(password_file),
                           "--oidc-group", policy["oidcGroup"]]
              if policy["bootstrap"]:
                  arguments.append("--bootstrap")
              run(["${waitForApi}"], timeout=65)
              validate_result(run(arguments, timeout=120).stdout, policy["oidcGroup"])
              current_configmap, current_policy = desired()
              current_secret = get("secret", "dependency-track-admin")
              current_deployment, current_pod = select()
              if (identity(current_deployment, current_pod) != expected
                      or json.loads(broker_record.read_text()) != expected
                      or current_policy != policy
                      or any(current["metadata"][key] != previous["metadata"][key]
                             for current, previous in ((current_configmap, configmap), (current_secret, secret))
                             for key in ("uid", "resourceVersion"))):
                  raise ValueError()
              set_condition(current_pod, True)

          try:
              if int(Path("/proc/sys/net/ipv4/ip_unprivileged_port_start").read_text()) <= ${toString apiPort}:
                  raise ValueError()
              if sys.argv[1] == "broker":
                  deployment, pod = select()
                  temporary = broker_record.with_suffix(".tmp")
                  temporary.write_text(json.dumps(identity(deployment, pod)))
                  temporary.chmod(0o400)
                  temporary.replace(broker_record)
                  os.execv(kubectl[0], kubectl + [
                      "port-forward", "--address=127.0.0.1", "--pod-running-timeout=60s",
                      "pod/" + pod["metadata"]["name"], "${toString apiPort}:8080"])
              if sys.argv[1] != "reconcile":
                  raise ValueError()
              def interrupted(signum, frame):
                  raise RuntimeError()
              signal.signal(signal.SIGTERM, interrupted)
              signal.signal(signal.SIGINT, interrupted)
              reconcile()
              print("Dependency-Track access policy verified for the current API Pod")
          except Exception:
              if sys.argv[1] == "reconcile":
                  # Reserve a separate bounded failure fence even after the command deadline.
                  deadline = time.monotonic() + 25
                  try:
                      _, pods = current_pods()
                      for pod in pods:
                          try:
                              set_condition(pod, False)
                          except Exception:
                              pass
                  except Exception:
                      pass
              print("Dependency-Track access-policy reconciliation failed", file=sys.stderr)
              sys.exit(1)
          finally:
              if sys.argv[1] == "reconcile":
                  (runtime / "admin-password").unlink(missing_ok=True)
        '';
        reconcileAccess = pkgs.writeShellScript "dependency-track-access-policy" ''
          exec ${pkgs.python3}/bin/python3 -B ${accessPolicyProgram} reconcile
        '';
        brokerAccess = pkgs.writeShellScript "dependency-track-access-policy-broker" ''
          exec ${pkgs.python3}/bin/python3 -B ${accessPolicyProgram} broker
        '';
        notifyFailure = pkgs.writeShellScript "dependency-track-sync-failure" ''
          set -euo pipefail
          umask 077
          test "$EUID" -eq 0
          runtime="''${RUNTIME_DIRECTORY:?}"
          export HOME="$runtime"
          export XDG_CACHE_HOME="$runtime/cache"
          socket="$runtime/proxy.sock"
          ${pkgs.coreutils}/bin/mkdir -p "$runtime/cache"
          read -r event_id < /proc/sys/kernel/random/uuid

          # create --raw leaves Content-Type unset; stock Alertmanager requires JSON.
          # The native UNIX listener is owner-only and never opens a TCP port.
          ${lib.getExe' config.services.k3s.package.k3sBundle "kubectl"} \
            --cache-dir="$runtime/cache" --request-timeout=30s proxy \
            --unix-socket="$socket" \
            --accept-hosts='^localhost$' \
            --accept-paths='^/api/v1/namespaces/monitoring/services/http:alertmanager:9093/proxy/api/v2/alerts$' \
            --reject-methods='^(GET|HEAD|PUT|PATCH|DELETE|CONNECT|OPTIONS|TRACE)$' \
            >/dev/null 2>&1 &
          proxy_pid=$!
          cleanup() {
            kill "$proxy_pid" 2>/dev/null || true
            wait "$proxy_pid" 2>/dev/null || true
          }
          trap cleanup EXIT
          trap 'exit 1' HUP INT TERM
          for attempt in {1..50}; do
            kill -0 "$proxy_pid" 2>/dev/null || break
            test ! -S "$socket" || break
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          if ! kill -0 "$proxy_pid" 2>/dev/null || test ! -S "$socket"; then
            echo "Dependency-Track failure notification transport unavailable" >&2
            exit 1
          fi

          if ! status=$(
            {
              ${pkgs.jq}/bin/jq -cn \
                --arg host ${lib.escapeShellArg host.name} \
                --arg event_id "$event_id" \
                '[{
                  labels: {
                    alertname: "DependencyTrackInventoryRefreshFailed",
                    source: "systemd",
                    namespace: "dependency-track",
                    severity: "warning",
                    host: $host,
                    event_id: $event_id
                  },
                  annotations: {
                    summary: ("Automatic inventory refresh failed on " + $host + ". Last-good inventories remain; latest coverage is unknown. Inspect dependency-track-sync.service and its retained journal. Notification expiry is not recovery.")
                  }
                }]' \
                | ${pkgs.curl}/bin/curl --disable --silent --fail \
                  --unix-socket "$socket" --noproxy '*' \
                  --connect-timeout 3 --max-time 30 \
                  --request POST --header 'Content-Type: application/json' \
                  --data-binary @- --output /dev/null --write-out '%{http_code}' \
                  'http://localhost/api/v1/namespaces/monitoring/services/http:alertmanager:9093/proxy/api/v2/alerts'
            } 2>/dev/null
          ) || test "$status" != 200; then
            echo "Dependency-Track failure notification request failed" >&2
            exit 1
          fi
        '';
      in
      {
        nix.settings.allowed-users = [ name ];
        assertions = [
          {
            assertion = config.nix.enable;
            message = "Dependency-Track ingestion requires the existing Nix daemon for pinned host provenance.";
          }
          {
            assertion = lib.any (user: lib.elem user allowedNixUsers) [
              name
              "@${name}"
              "*"
            ];
            message = "Dependency-Track ingestion requires non-trusted Nix daemon access for ${name}.";
          }
          {
            assertion = !requestedPrivateAccess || computeGuest;
            message = "Dependency-Track private access requires the explicitly paired compute-guest workload variant.";
          }
        ]
        ++ lib.optionals computeGuest [
          {
            assertion = config.services.k3s.enable;
            message = "Dependency-Track compute-guest ingestion requires the existing local K3s management service.";
          }
          {
            assertion = cfg.apiUrl == "http://127.0.0.1:${toString apiPort}";
            message = "Dependency-Track compute-guest ingestion uses only its fixed private loopback broker.";
          }
          {
            assertion = unprivilegedPortStart == null || lib.toInt (toString unprivilegedPortStart) > apiPort;
            message = "Dependency-Track compute-guest transport requires a reserved TCP port; do not lower ip_unprivileged_port_start past ${toString apiPort}.";
          }
          {
            assertion =
              !requestedPrivateAccess
              || (
                builtins.length (builtins.attrNames pairedClusters) == 1
                && builtins.attrNames selectedClusters == builtins.attrNames pairedClusters
              );
            message = "Dependency-Track private access requires exactly one paired, explicitly selected service on this compute guest.";
          }
        ];
        # A dedicated non-login identity; numeric ownership survives recovery.
        users.users.${name} = {
          uid = 705;
          isSystemUser = true;
          group = name;
        };
        users.groups.${name}.gid = 705;
        systemd.tmpfiles.rules = lib.optionals (!computeGuest) [
          "d ${stateDirectory} 0700 ${name} ${name} -"
        ];
        environment.systemPackages = [ package ];
        systemd.services =
          lib.optionalAttrs computeGuest {
            dependency-track-sync-credentials = {
              description = "Project only the reconciled ingestor credentials for systemd";
              requires = [
                "k3s.service"
                "kubernetes-runtime-secrets.service"
              ];
              after = [
                "k3s.service"
                "kubernetes-runtime-secrets.service"
              ];
              unitConfig.RequiresMountsFor = [ "/srv/secrets" ];
              environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
              serviceConfig = {
                Type = "oneshot";
                User = "root";
                Group = "root";
                UMask = "0077";
                RuntimeDirectory = "dependency-track-sync-credentials";
                RuntimeDirectoryMode = "0700";
                RuntimeDirectoryPreserve = "yes";
                ExecStart = stageCredentials;
                TimeoutStartSec = "45s";
                NoNewPrivileges = true;
                ProtectHome = true;
                ProtectSystem = "strict";
                ReadWritePaths = [ credentialDirectory ];
                PrivateTmp = true;
              };
            };
            dependency-track-sync-api-tunnel = {
              description = "Private fixed-command Dependency-Track loopback transport";
              wantedBy = [ "k3s.service" ];
              partOf = [ "k3s.service" ];
              requires = [
                "k3s.service"
                "kubernetes-runtime-secrets.service"
              ];
              after = [
                "k3s.service"
                "kubernetes-runtime-secrets.service"
              ];
              unitConfig.StartLimitIntervalSec = 0;
              environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
              serviceConfig = {
                Type = "exec";
                User = "root";
                Group = "root";
                RuntimeDirectory = "dependency-track-sync-api-tunnel";
                RuntimeDirectoryMode = "0700";
                ExecStartPre = requireReservedPort;
                ExecStart =
                  if privateAccess then
                    brokerAccess
                  else
                    "${kubectl} --cache-dir=${brokerRuntime}/kube-cache port-forward --address=127.0.0.1 --pod-running-timeout=60s service/dependency-track-api ${toString apiPort}:8080";
                Restart = "always";
                RestartSec = "15s";
                UMask = "0077";
                CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
                AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
                ReadWritePaths = [ brokerRuntime ];
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                ];
                StandardOutput = "null";
                StandardError = "null";
                NoNewPrivileges = true;
                ProtectHome = true;
                ProtectSystem = "strict";
                PrivateTmp = true;
              };
            };
            dependency-track-sync-failure = {
              description = "Report automatic inventory refresh failure through private monitoring";
              after = [ "k3s.service" ];
              environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
              serviceConfig = {
                Type = "oneshot";
                User = "root";
                Group = "root";
                UMask = "0077";
                RuntimeDirectory = "dependency-track-sync-failure";
                RuntimeDirectoryMode = "0700";
                ExecStart = notifyFailure;
                TimeoutStartSec = "45s";
                CapabilityBoundingSet = "";
                NoNewPrivileges = true;
                ProtectHome = true;
                ProtectSystem = "strict";
                PrivateTmp = true;
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                ];
              };
            };
          }
          // lib.optionalAttrs privateAccess {
            dependency-track-access-policy = {
              description = "Reconcile stock Dependency-Track access policy and admit the current API Pod";
              # Wants, not Requires: transport/dependency failure must still execute
              # the controller's False fence for any previously admitted Pod.
              wants = [
                "k3s.service"
                "kubernetes-runtime-secrets.service"
                "dependency-track-sync-api-tunnel.service"
              ];
              after = [
                "k3s.service"
                "kubernetes-runtime-secrets.service"
                "dependency-track-sync-api-tunnel.service"
              ];
              unitConfig.RequiresMountsFor = [ "/srv/secrets" ];
              environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
              serviceConfig = {
                Type = "oneshot";
                User = "root";
                Group = "root";
                UMask = "0077";
                RuntimeDirectory = "dependency-track-access-policy";
                RuntimeDirectoryMode = "0700";
                ExecStart = reconcileAccess;
                TimeoutStartSec = "5min";
                TimeoutStopSec = "30s";
                MemoryMax = "256M";
                TasksMax = 64;
                CPUQuota = "50%";
                CapabilityBoundingSet = "";
                NoNewPrivileges = true;
                ProtectHome = true;
                ProtectSystem = "strict";
                PrivateTmp = true;
                PrivateDevices = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectControlGroups = true;
                RestrictSUIDSGID = true;
                ReadWritePaths = [ policyRuntime ];
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                ];
              };
            };
          }
          // {
            ${name} = {
              description = "Acquire trusted sealed inventories and refresh private Dependency-Track with host provenance";
              onFailure = lib.optionals computeGuest [ "dependency-track-sync-failure.service" ];
              wants = [
                "network-online.target"
              ]
              ++ lib.optionals computeGuest [
                "dependency-track-sync-credentials.service"
                "dependency-track-sync-api-tunnel.service"
              ];
              after = [
                "network-online.target"
              ]
              ++ lib.optionals computeGuest [
                "dependency-track-sync-credentials.service"
                "dependency-track-sync-api-tunnel.service"
              ];
              unitConfig.RequiresMountsFor = [
                # Source artifacts are acquired automatically; only private evidence is mounted.
                stateDirectory
              ];
              environment = {
                HOME = stateDirectory;
                XDG_CACHE_HOME = "${stateDirectory}/cache";
              };
              preStart = lib.optionalString computeGuest ''
                test -s /srv/state/.homelab-state-root
                test -d ${lib.escapeShellArg stateDirectory}
              '';
              serviceConfig = {
                Type = "oneshot";
                User = name;
                Group = name;
                UMask = "0077";
                TimeoutStartSec = "2h";
                # A failed dependency job alone does not fail the importer. These
                # fixed manager-owned root invocations do, preserving OnFailure.
                # '+' bypasses User/filesystem sandbox only for systemctl; no 705
                # command, home, argument or credential enters this root process.
                ExecStartPre =
                  lib.optionals privateAccess [
                    "+${pkgs.coreutils}/bin/env -i ${pkgs.systemd}/bin/systemctl --system --no-ask-password --no-pager start --wait dependency-track-access-policy.service"
                  ]
                  ++ lib.optionals computeGuest [
                    "+${pkgs.coreutils}/bin/env -i ${pkgs.systemd}/bin/systemctl --system --no-ask-password --no-pager start --wait dependency-track-sync-credentials.service"
                    requireReservedPort
                    waitForApi
                  ];
                InaccessiblePaths = lib.optionals computeGuest [
                  "/etc/rancher/k3s"
                  "/var/lib/rancher/k3s"
                  "/srv/secrets"
                  credentialDirectory
                  policyRuntime
                  brokerRuntime
                ];
                LoadCredential = [
                  "api-key:${apiKeyPath}"
                  "github-token:${githubTokenPath}"
                ];
                ExecStart = lib.escapeShellArgs (
                  [
                    "${package}/bin/dependency-track-sync"
                    "refresh"
                    "--api-url"
                    cfg.apiUrl
                    "--api-key-file"
                    "%d/api-key"
                    "--github-token-file"
                    "%d/github-token"
                    "--repository"
                    cfg.repository
                    "--branch"
                    cfg.branch
                    "--max-age-seconds"
                    (toString cfg.maxAgeSeconds)
                    "--state-dir"
                    stateDirectory
                  ]
                  ++ (
                    if cfg.targetIds != [ ] then
                      lib.concatMap (target: [
                        "--target"
                        target
                      ]) cfg.targetIds
                    else
                      lib.concatMap (state: [
                        "--scope"
                        state
                      ]) cfg.sourceStates
                  )
                );
                NoNewPrivileges = true;
                PrivateTmp = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                ReadWritePaths = [ stateDirectory ];
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                ];
              };
            };
          };
        systemd.timers =
          lib.optionalAttrs (cfg.onCalendar != null) {
            ${name} = {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = cfg.onCalendar;
                OnBootSec = lib.mkIf computeGuest "2min";
                Persistent = true;
              };
            };
          }
          // lib.optionalAttrs privateAccess {
            dependency-track-access-policy = {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnBootSec = "30s";
                OnUnitInactiveSec = "1min";
                AccuracySec = "5s";
              };
            };
          };
      }
      // lib.optionalAttrs (!computeGuest) {
        secretRequests = {
          dependency-track-sync-api-key = {
            provider = "agenix";
            ageFile = host.secretPath + "/dependency-track-sync-api-key.age";
            mode = "0400";
            owner = "root";
            group = "root";
          };
          dependency-track-sync-github-token = {
            provider = "agenix";
            ageFile = host.secretPath + "/dependency-track-sync-github-token.age";
            mode = "0400";
            owner = "root";
            group = "root";
          };
        };
      };
  };
}
