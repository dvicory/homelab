{ den, lib, inputs, ... }: {
  den.aspects.core."remote-unlock" = {
    nixos = { host, config, pkgs, ... }: let
      poolName = host.zfs.rootPool.name or null;
      sshUserNames = host.settings.core.remote-unlock.sshUsers or [ "daniel" ];
      sshKeys = lib.concatLists (
        lib.mapAttrsToList (_name: userCfg: userCfg.sshKeys or [ ])
          (lib.filterAttrs (n: _v: lib.elem n sshUserNames) host.users)
      );
      authorizedKeysFile = pkgs.writeText "hoopsnake-keys" (
        lib.concatStringsSep "\n" (lib.concatMap (path: lib.splitString "\n" (builtins.readFile path)) sshKeys)
      );
    in {
      imports = [ inputs.hoopsnake.nixosModules.default ];

      config = lib.mkIf (host.hasAspect den.aspects.disk.zfs) {
        boot.initrd = {
          network.enable = true;
          systemd = {
            enable = true;
            network.enable = true;
            network.networks = lib.mapAttrs (name: iface: {
              matchConfig.Name = name;
              address = lib.optional (iface ? ipv4 && iface.ipv4 != null) iface.ipv4;
              gateway = lib.optional (iface ? gateway && iface.gateway != null) iface.gateway;
              networkConfig.DHCP = if iface.dhcp or false then "yes" else "no";
            }) (lib.filterAttrs (_: iface: iface.initrd.enable or false) (host.networking.interfaces or { }));
            emergencyAccess = true;
            extraBin = {
              ping = "${pkgs.iputils}/bin/ping";
              trip = "${pkgs.trippy}/bin/trip";
              ip = "${pkgs.iproute2}/bin/ip";
              vi = "${pkgs.vim}/bin/vi";
            };
          };
        };

        environment.systemPackages = [
          inputs.hoopsnake.packages.${pkgs.system}.hoopsnake
        ];

        boot.initrd.network.hoopsnake = {
          enable = true;
          ssh.authorizedKeysFile = authorizedKeysFile;
          systemd-credentials = {
            privateHostKey.file = "/boot/boot_host_key";
            privateHostKey.encrypted = false;
            clientId.text = "kXUenK1hK411CNTRL";
            clientId.encrypted = false;
            clientSecret.file = "/boot/tailscale_client_secret";
            clientSecret.encrypted = false;
          };
          tailscale = {
            name = "hoopsnake-${config.networking.hostName}";
            tags = [ "tag:hoopsnake" ];
            tsnetVerbose = true;
            cleanup = {
              deleteExisting = true;
              maxNodeAge = "10s";
            };
          };
        };
      };
    };
  };
}
