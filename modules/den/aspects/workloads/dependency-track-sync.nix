{
  den,
  lib,
  inputs,
  ...
}:
{
  den.aspects.workloads.dependency-track-sync = {
    # Explicit paired selection: also enable the service's automaticInventory
    # resource inputs. Neither this variant nor the service selects a real host.
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
        kubectl = "${config.services.k3s.package}/bin/k3s kubectl --namespace dependency-track";
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
                ExecStart = "${kubectl} --cache-dir=/run/dependency-track-sync-api-tunnel/kube-cache port-forward --address=127.0.0.1 --pod-running-timeout=60s service/dependency-track-api ${toString apiPort}:8080";
                Restart = "always";
                RestartSec = "15s";
                NoNewPrivileges = true;
                ProtectHome = true;
                ProtectSystem = "strict";
                PrivateTmp = true;
              };
            };
          }
          // {
            ${name} = {
              description = "Acquire trusted sealed inventories and refresh private Dependency-Track with host provenance";
              wants = [ "network-online.target" ];
              requires = lib.optionals computeGuest [
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
                ExecStartPre = lib.optionals computeGuest [
                  requireReservedPort
                  waitForApi
                ];
                InaccessiblePaths = lib.optionals computeGuest [
                  "/etc/rancher/k3s"
                  "/var/lib/rancher/k3s"
                  "/srv/secrets"
                  credentialDirectory
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
        systemd.timers = lib.optionalAttrs (cfg.onCalendar != null) {
          ${name} = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = cfg.onCalendar;
              OnBootSec = lib.mkIf computeGuest "2min";
              Persistent = true;
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
