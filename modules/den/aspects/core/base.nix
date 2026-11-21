# Base system configuration — defaults for every host.
# Moved from defaults.nix den.default.nixos to avoid inputs.self recursion.
{ lib, ... }:
{
  den.aspects.core.base = {
    nixos = { config, lib, pkgs, ... }: let
      inherit (lib) mkOption types;
      kernelVersion = config.boot.kernelPackages.kernel.version;
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
        boot.kernelPatches = lib.optional (
          lib.versionAtLeast kernelVersion "6.18"
          && lib.versionOlder kernelVersion "6.18.55"
        ) {
          name = "CVE-2026-98624";
          patch = ./kernel-nfqueue.patch;
        };
      };
    };
  };
}
