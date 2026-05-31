{ lib, ... }: {
  den.schema.host = { host, lib, ... }: {
    options.environment = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Environment grouping for this host (e.g. home, vms)";
    };

    options.disk.device = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = host.zfs.rootPool.disk1 or null;
      description = "Root disk device for disko layout (defaults to ZFS pool disk)";
    };

    options.zfs = {
      rootPool = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "ZFS pool name for the root pool.";
            };
            disk1 = lib.mkOption {
              type = lib.types.str;
              description = "Primary disk device for the root pool.";
            };
          };
        });
        default = null;
        description = "ZFS root pool configuration.";
      };

      swap = {
        enable = lib.mkEnableOption "swap partition via disko";
        size = lib.mkOption {
          type = lib.types.str;
          default = "8G";
          description = "Size of the swap partition.";
        };
      };
    };

    options.networking.interfaces = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          ipv4 = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "IPv4 address with CIDR prefix.";
          };
          gateway = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default gateway for this interface.";
          };
          dhcp = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Use DHCP on this interface.";
          };
          initrd = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable this interface in initrd.";
            };
          };
        };
      });
      default = { };
      description = "Network interface configurations for this host.";
    };

    options.settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = lib.types.attrsOf lib.types.anything;
        options = {
          disk.backend = lib.mkOption {
            type = lib.types.enum [ "zfs" "ext4" ];
            default = "zfs";
          };
          disk.encryption.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          disk.swap.size = lib.mkOption {
            type = lib.types.str;
            default = "8G";
          };
          networking.firewall.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          networking.dns.overTls = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          hypervisor.incus.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          hypervisor.incus.webUiPort = lib.mkOption {
            type = lib.types.int;
            default = 8443;
          };
          time.chrony.servers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "time.cloudflare.com" "time.google.com" ];
          };
          time.chrony.enableNts = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          core.impermanence.rollback.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          core.remote-unlock.sshUsers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "daniel" ];
            description = "Usernames whose SSH keys are authorized for remote-unlock (hoopsnake).";
          };
          core.remote-unlock.tailscale.authKey = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
        };
      };
      default = { };
    };
  };
}
