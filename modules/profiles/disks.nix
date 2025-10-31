{ inputs, self, ... }:
{
  flake-file.inputs = {
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    nixos-anywhere.inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules.nixos.profiles-disks =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      hostCfg = inputs.self.dlab.hosts.${config.dlab.hostName};
      diskCfg = config.dlab.diskConfig;
    in
    {
      imports = [
        inputs.nixos-anywhere.inputs.disko.nixosModules.disko
      ];

      options.dlab.diskConfig = lib.mkOption {
        type = lib.types.submodule {
          options = {
            swap = {
              enable = lib.mkEnableOption "Enable swap setup via disko.";
              size = lib.mkOption {
                type = lib.types.str;
                default = "8G";
                description = "Size of the swap partition.";
              };
            };
          };
        };
        default = { };
      };

      config = {
        disko.devices = {
          disk =
            let
              hasRaid = hostCfg.rootPool.disk2 != null;

              mkRoot =
                {
                  disk,
                  id ? "",
                }:
                {
                  type = "disk";
                  device = disk;
                  content = {
                    type = "gpt";
                    partitions = {
                      ESP = {
                        size = "1G";
                        type = "EF00";
                        content = {
                          type = "filesystem";
                          format = "vfat";
                          mountpoint = "/boot${id}";
                          # Otherwise you get https://discourse.nixos.org/t/security-warning-when-installing-nixos-23-11/37636/2
                          mountOptions = [ "umask=0077" ];
                          # Copy the host_key needed for initrd in a location accessible on boot.
                          # It's prefixed by /mnt because we're installing and everything is mounted under /mnt.
                          # We're using the same host key because, well, it's the same host!
                          postMountHook = ''
                            install -D -m 600 /tmp/boot_host_key /mnt/boot${id}/boot_host_key
                            echo "Installed boot host key at /mnt/boot${id}/boot_host_key for boot SSH access"
                            install -D -m 600 /tmp/tailscale_client_secret /mnt/boot${id}/tailscale_client_secret
                            echo "Installed Tailscale client secret at /mnt/boot${id}/tailscale_client_secret for Hoopsnake remote unlock"
                          '';
                        };
                      };
                      swap = lib.mkIf diskCfg.swap.enable {
                        size = diskCfg.swap.size;
                        uuid = "bc5dda00-e581-451d-9940-16fdd5417a0e";
                        content = {
                          type = "swap";
                          discardPolicy = "once"; # Enable TRIM on swap
                          randomEncryption = true;
                        };
                      };
                      zfs = {
                        size = "100%";
                        content = {
                          type = "zfs";
                          pool = hostCfg.rootPool.name;
                        };
                      };
                    };
                  };
                };
            in
            {
              root = mkRoot { disk = hostCfg.rootPool.disk1; };
              # Second root must have id=-backup.
              root1 = lib.mkIf hasRaid (mkRoot {
                disk = hostCfg.rootPool.disk2;
                id = "-backup";
              });
            };
          zpool = {
            ${hostCfg.rootPool.name} = {
              type = "zpool";
              mode = if hostCfg.rootPool.disk2 != null then "mirror" else "";
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
              # Need to use another variable name otherwise I get SC2030 and SC2031 errors.
              preCreateHook = ''
                pname=$name
              '';
              # Needed to get back a prompt on next boot.
              # See https://github.com/nix-community/nixos-anywhere/issues/161#issuecomment-1642158475
              postCreateHook = ''
                zfs set keylocation="prompt" $pname
              '';

              # Follows https://grahamc.com/blog/erase-your-darlings/
              datasets = {
                "local/root" = {
                  type = "zfs_fs";
                  mountpoint = "/";
                  options.mountpoint = "legacy";
                  postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^${hostCfg.rootPool.name}/local/root@blank$' || zfs snapshot ${hostCfg.rootPool.name}/local/root@blank";
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

                # TODO: we create this whether impermanence is on or not
                # we also hardcoded /persist yet allow a configurable path
                "safe/persist" = {
                  type = "zfs_fs";
                  mountpoint = "/persist";
                  # It's prefixed by /mnt because we're installing and everything is mounted under /mnt.
                  options.mountpoint = "legacy";
                  postMountHook = ''
                    # This must happen during disko, before nixos-install runs, so that
                    # SOPS can use it to decrypt secrets during system activation
                    install -D -m 600 /tmp/runtime_host_key /mnt/persist/etc/ssh/ssh_host_ed25519_key
                    echo "Installed runtime host key at /persist/etc/ssh/ssh_host_ed25519_key for SOPS decryption"
                  '';
                };
              };
            };
          };
        };

        boot.supportedFilesystems = [
          "vfat"
          "zfs"
        ];
        boot.zfs.forceImportRoot = false;

        # This is needed to make the /boot*/host_key and /persist runtime key available early
        # enough to be able to decrypt the sops file on boot,
        # when the /etc/shadow file is first generated.
        # We assume mkRoot will always be called with at least id=1.
        fileSystems = {
          "/boot".neededForBoot = true;
          "/boot-backup" = lib.mkIf (hostCfg.rootPool.disk2 != null) { neededForBoot = true; };
        };

        # Setup Grub to support UEFI.
        # nodev is for UEFI.
        boot.loader.grub = {
          enable = true;
          efiSupport = true;
          efiInstallAsRemovable = true;

          mirroredBoots = lib.mkForce (
            [
              {
                path = "/boot";
                devices = [ "nodev" ];
              }
            ]
            ++ (lib.optionals (hostCfg.rootPool.disk2 != null) [
              {
                path = "/boot-backup";
                devices = [ "nodev" ];
              }
            ])
          );
        };

        services.zfs.autoScrub.enable = true;
      };
    };
}
