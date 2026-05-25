{ lib, ... }: {
  den.aspects."core/nix" = {
    os = { host, lib, ... }: {
      nix.settings = {
        experimental-features = [ "nix-command" "flakes" ];
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
        auto-optimise-store = true;
        builders-use-substitutes = true;
        fallback = true;
        keep-outputs = true;
        keep-derivations = true;
      };

      nix.gc = lib.mkIf host.settings.core.nix.gc.enable {
        automatic = true;
        options = "--delete-older-than 14d";
      };
    };

    nixos = _: {
      nix = {
        settings = {
          trusted-users = [ "root" "@wheel" ];
          allowed-users = [ "root" "@wheel" ];
        };
        gc.dates = "05:00";
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
      nix.settings = {
        trusted-users = [ "root" "@admin" ];
        allowed-users = [ "root" "@admin" ];
      };
      nix.gc.interval = { Hour = 5; Minute = 0; };
    };
  };

  den.schema.host.options.settings.core.nix.gc.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable automatic nix store garbage collection";
  };

  den.schema.host.options.nix.allowedUnfree = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
  };
}
