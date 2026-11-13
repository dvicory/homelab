{ lib, inputs, ... }:
{
  den.aspects.workloads.dependency-track-sync = {
    settings = {
      apiUrl = lib.mkOption {
        type = lib.types.str;
        description = "Supported private Dependency-Track API URL; this does not establish a listener or grant network access.";
      };
      inventoryDirectory = lib.mkOption {
        type = lib.types.strMatching "/.*";
        description = "Already acquired and admitted sealed PR120 inventory directory. Acquisition and fleet enrollment remain separate explicit operations.";
      };
      stateDirectory = lib.mkOption {
        type = lib.types.strMatching "/.*";
        default = "/var/lib/dependency-track-sync";
        description = "Durable canonical originals/provenance and single-writer lifecycle journal, deliberately persisted independently of the service database.";
      };
      onCalendar = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Opt-in sync schedule; null leaves an explicitly started oneshot only. Never collects or enrolls a fleet implicitly.";
      };
    };
    persist = { host, ... }: [
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
      in
      {
        # A dedicated non-login identity; numeric ownership survives recovery.
        users.users.${name} = {
          isSystemUser = true;
          group = name;
        };
        users.groups.${name} = { };
        secretRequests.dependency-track-sync-api-key = {
          provider = "agenix";
          ageFile = host.secretPath + "/dependency-track-sync-api-key.age";
          mode = "0400";
          owner = "root";
          group = "root";
        };
        systemd.tmpfiles.rules = [ "d ${cfg.stateDirectory} 0700 ${name} ${name} -" ];
        environment.systemPackages = [ package ];
        systemd.services.${name} = {
          description = "Synchronize an admitted sealed inventory with private Dependency-Track";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          unitConfig.RequiresMountsFor = [
            cfg.inventoryDirectory
            cfg.stateDirectory
          ];
          serviceConfig = {
            Type = "oneshot";
            User = name;
            Group = name;
            UMask = "0077";
            LoadCredential = "api-key:${config.age.secrets.dependency-track-sync-api-key.path}";
            ExecStart = lib.escapeShellArgs [
              "${package}/bin/dependency-track-sync"
              "sync"
              "--api-url"
              cfg.apiUrl
              "--api-key-file"
              "%d/api-key"
              "--inventory"
              cfg.inventoryDirectory
              "--state-dir"
              cfg.stateDirectory
            ];
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ReadWritePaths = [ cfg.stateDirectory ];
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
          };
        };
        systemd.timers = lib.optionalAttrs (cfg.onCalendar != null) {
          ${name} = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = cfg.onCalendar;
              Persistent = true;
            };
          };
        };
      };
  };
}
