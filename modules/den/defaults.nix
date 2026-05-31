{ den, lib, inputs, ... }:
{
  den.reservedKeys = [ "settings" ];

  den.default.includes = [
    den.batteries.hostname
    den.batteries.mutual-provider
    den.batteries.define-user
    ({ user, ... }: {
      nixos.users.users.${user.userName}.openssh.authorizedKeys.keys = user.sshKeys or [ ];
    })
    ({ host, user }: let
      secretPath = inputs.self + "/modules/den/hosts/${host.name}/secrets.yaml";
      hasSecrets = builtins.pathExists secretPath;
    in lib.optionalAttrs hasSecrets {
      nixos = {
        users.users.${user.userName} = {
          extraGroups = user.extraGroups or [ ];
          hashedPasswordFile = "/run/secrets-for-users/users/${user.userName}/hashedPassword";
        };
        secretRequests."users/${user.userName}/hashedPassword" = {
          mode = "0400";
          owner = "root";
          neededForUsers = true;
        };
      };
    })
  ];

  den.schema.host.includes = [
    den.aspects.disk
    den.aspects.core."firewall-collector"
    den.aspects.core.time
    den.aspects.networking.default
    den.aspects.core.nix
    den.aspects.core.sudo
  ];

  den.default.nixos = { config, lib, pkgs, ... }: let
    inherit (lib) mkOption types;
  in {
    options = {
      deployment = {
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
        };
      };
    };

    config = {
      environment.systemPackages = with pkgs; [ bottom lnav git ];
      programs.vim.enable = lib.mkDefault true;

      system.stateVersion = "26.05";

      boot.initrd.systemd.emergencyAccess = true;

      users.mutableUsers = false;

      services.openssh = {
        enable = lib.mkDefault true;
        settings = {
          PermitRootLogin = lib.mkDefault "no";
          PasswordAuthentication = lib.mkDefault false;
        };
      };
    };
  };

  den.default.homeManager.home.stateVersion = "26.05";
  den.default.darwin.system.stateVersion = 6;
}
