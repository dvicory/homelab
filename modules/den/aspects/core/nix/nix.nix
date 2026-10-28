{ lib, ... }:
{
  den.aspects.core.nix = {
    settings = {
      gc.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable automatic nix store garbage collection";
      };
    };

    os =
      { host, ... }:
      {
        imports = [ (import ../../../../nix/caches.nix).flake.modules.generic.nix-common ];

        nix.settings = {
          experimental-features = [
            "nix-command"
            "flakes"
          ];
          connect-timeout = 5;
          log-lines = 50;
          min-free = 128000000;
          max-free = 1000000000;
          download-buffer-size = 524288000;
          auto-optimise-store = true;
          builders-use-substitutes = true;
          fallback = true;
          keep-outputs = true;
          keep-derivations = true;
        };
      };

    nixos =
      { host, lib, ... }:
      {
        nix = {
          settings =
            let
              users = [
                "root"
                "@wheel"
              ];
            in
            {
              trusted-users = users;
              allowed-users = users;
            };

          gc = lib.mkIf (host.settings.core.nix.gc.enable or true) {
            dates = "05:00";
          };
          daemonCPUSchedPolicy = lib.mkDefault "batch";
          daemonIOSchedClass = lib.mkDefault "idle";
          daemonIOSchedPriority = lib.mkDefault 7;
        };

        systemd = {
          services.nix-gc.serviceConfig = {
            CPUSchedulingPolicy = "batch";
            IOSchedulingClass = "idle";
            IOSchedulingPriority = 7;
          };
        };
      };

    darwin = {
      nix.settings =
        let
          users = [
            "root"
            "@admin"
          ];
        in
        {
          trusted-users = users;
          allowed-users = users;
        };
      nix.gc = {
        automatic = true;
        interval = {
          Hour = 5;
          Minute = 0;
        };
        options = "--delete-older-than 30d";
      };
    };
  };
}
