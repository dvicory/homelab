{ lib, self, ... }: {
  den.aspects.disk.zfs.provides.pool = {
    age-secrets = { host, ... }: {
      age.secrets.zfs-passphrase = {
        rekeyFile = self + "/.secrets/hosts/${host.name}/zfs-passphrase.age";
        mode = "0400";
        owner = "root";
        group = "root";
      };
    };

    nixos = { host, pkgs, ... }: let
      pool = host.zfs.rootPool or null;
      swapCfg = host.zfs.swap or { };
      mirrorEnabled = pool.disk2 != null;
      espSizeGiB = pool.espSizeGiB or 1;
      tailReserveGiB = pool.tailReserveGiB or 0;
      swapEnabled = swapCfg.enable or false;
      swapSizeGiB = swapCfg.sizeGiB or 8;
      trailingGiB = tailReserveGiB + (if swapEnabled then swapSizeGiB else 0);
      zfsEnd = if trailingGiB == 0 then "-0" else "-${toString trailingGiB}G";
    in {
      config = {
        disko.devices = {
          disk.root = {
            type = "disk";
            device = host.disk.device;
            content = {
              type = "gpt";
              partitions = {
                ESP = {
                  priority = 1000;
                  size = "${toString espSizeGiB}G";
                  type = "EF00";
                  content = {
                    type = "filesystem";
                    format = "vfat";
                    mountpoint = "/boot";
                    mountOptions = [ "umask=0077" ];

                    postMountHook = ''
                      install -D -m 600 /tmp/boot_host_key /mnt/boot/boot_host_key
                      echo "Installed boot host key at /mnt/boot/boot_host_key for boot SSH access"
                      install -D -m 600 /tmp/tailscale_client_secret /mnt/boot/tailscale_client_secret
                      echo "Installed Tailscale client secret at /mnt/boot/tailscale_client_secret for Hoopsnake remote unlock"
                    '';
                  };
                };
                swap = lib.mkIf (swapCfg.enable or false) {
                  priority = 3000;
                  size = "${toString swapSizeGiB}G";
                  uuid = "bc5dda00-e581-451d-9940-16fdd5417a0e";
                  content = {
                    type = "swap";
                    discardPolicy = "once";
                    randomEncryption = true;
                  };
                };
                zfs = {
                  priority = 2000;
                  end = zfsEnd;
                  content = {
                    type = "zfs";
                    pool = pool.name;
                  };
                };
              };
            };
          };

          disk."root-mirror" = lib.mkIf mirrorEnabled {
            type = "disk";
            device = pool.disk2;
            content = {
              type = "gpt";
              partitions = {
                ESP = {
                  priority = 1000;
                  size = "${toString espSizeGiB}G";
                  type = "EF00";
                  content = {
                    type = "filesystem";
                    format = "vfat";
                    mountpoint = "/boot-mirror";
                    mountOptions = [
                      "umask=0077"
                      "nofail"
                      "x-systemd.device-timeout=5s"
                    ];
                  };
                };
                zfs = {
                  priority = 2000;
                  end = zfsEnd;
                  content = {
                    type = "zfs";
                    pool = pool.name;
                  };
                };
              };
            };
          };

          zpool.${pool.name} = {
            type = "zpool";
            mode = if mirrorEnabled then "mirror" else "";
            options = {
              ashift = "12";
              autotrim = "on";
            };
            rootFsOptions = {
              encryption = "on";
              keyformat = "passphrase";
              keylocation = "file:///tmp/root_passphrase";
              compression = "lz4";
              canmount = "off";
              xattr = "sa";
              atime = "off";
              acltype = "posixacl";
              recordsize = "1M";
              "com.sun:auto-snapshot" = "false";
            };
            preCreateHook = "pname=$name";
            postCreateHook = "zfs set keylocation=\"prompt\" $pname";
            datasets = {
              "local/root" = {
                type = "zfs_fs";
                mountpoint = "/";
                options.mountpoint = "legacy";
                postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^${pool.name}/local/root@blank$' || zfs snapshot ${pool.name}/local/root@blank";
              };
              "local/nix" = {
                type = "zfs_fs";
                mountpoint = "/nix";
                options.mountpoint = "legacy";
              };
              "safe/home" = {
                type = "zfs_fs";
                mountpoint = "/home";
                options.mountpoint = "legacy";
              };
              "safe/persist" = {
                type = "zfs_fs";
                mountpoint = "/persist";
                options.mountpoint = "legacy";

                postMountHook = ''
                  install -D -m 600 /tmp/runtime_host_key /mnt/persist/etc/ssh/ssh_host_ed25519_key
                  echo "Installed runtime host key at /persist/etc/ssh/ssh_host_ed25519_key for agenix rekeying"
                '';
              };
            };
          };
        };

        boot.loader.systemd-boot.extraInstallCommands = lib.mkIf mirrorEnabled ''
          if ${pkgs.util-linux}/bin/mountpoint -q /boot-mirror; then
            ${pkgs.rsync}/bin/rsync -rt --delete --exclude=/loader/random-seed /boot/ /boot-mirror/
            ${pkgs.systemd}/bin/bootctl --esp-path=/boot-mirror --variables=no random-seed
          else
            echo "Skipping mirror ESP update because /boot-mirror is not mounted" >&2
          fi
        '';
      };
    };
  };
}
