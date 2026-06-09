# Base system configuration — defaults for every host.
# Moved from defaults.nix den.default.nixos to avoid inputs.self recursion.
{ lib, ... }:
{
  den.aspects.core.base = {
    nixos = { lib, pkgs, ... }: let
      inherit (lib) mkOption types;
    in {
      options.deployment = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable deploy-rs deployment for this host.";
        };
        target = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        sshUser = mkOption {
          type = types.str;
          default = "root";
        };
        sshPort = mkOption {
          type = types.int;
          default = 22;
        };
        knownHostsPath = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Path to known_hosts file for deploy-rs SSH host key verification.";
        };
      };

      config = {
        environment.systemPackages = with pkgs; [
          bottom
          lnav
          git
        ];
        programs.vim.enable = lib.mkDefault true;

        boot.initrd.systemd.emergencyAccess = true;
      };
    };
  };
}
