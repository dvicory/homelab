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

    os = { host, ... }: {
      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        substituters = [
          "https://cache.nixos.org/"
          "https://nix-community.cachix.org"
          "https://cache.garnix.io"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
        ];
        connect-timeout = 5;
        log-lines = 50;
        min-free = 128000000;
        max-free = 1000000000;
        download-buffer-size = 524288000;
        # auto-optimise-store is incompatible with microvm.writableStoreOverlay
        auto-optimise-store = !(host.microvm.isGuest or false);
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
      nix.gc.interval = {
        Hour = 5;
        Minute = 0;
      };
    };
  };
}
