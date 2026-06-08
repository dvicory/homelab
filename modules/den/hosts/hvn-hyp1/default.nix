{ den, inputs, ... }: {
  den.hosts.x86_64-linux.hvn-hyp1 = {
    environment = "prod";
    system-access-groups = [ "system-access" ];

    settings = {
      core.nix.gc.enable = false;
      services.mergerfs.pools."/mnt/storage/media" = {
        branches = [
          "/mnt/storage-clear/media1"
          "/mnt/storage-clear/media2"
          "/mnt/storage-clear/media3"
        ];
      };
    };

    zfs = {
      rootPool = {
        name = "rpool";
        disk1 = "/dev/nvme0n1";
      };
      swap.enable = true;
    };

    networking.interfaces.eno1 = {
      ipv4 = "172.27.50.17/24";
      gateway = "172.27.50.1";
      initrd.enable = true;
    };
  };

  den.aspects.hvn-hyp1 = {
    includes = [
      den.aspects.core.facter
      den.aspects.core.base
      den.aspects.virtualization.incus
      den.aspects.disk.zfs
      den.aspects.disk.zfs.provides.pool
      den.aspects.disk.impermanence
      den.aspects.roles.server
      den.aspects.core."remote-unlock"
      den.aspects.services.mergerfs
      den.aspects.secrets.agenix
    ];

    nixos = { config, pkgs, lib, ... }: let
      mkGocryptfsMount = { name, device, passfile }: {
        fileSystems.${device} = {
          device = "/dev/disk/by-label/${baseNameOf device}";
          fsType = "btrfs";
          options = [ "noatime" ];
        };

        fileSystems.${name} = {
          device = "gocryptfs#${device}/crypt";
          fsType = "fuse.gocryptfs";
          options = [ "noauto" "allow_other" "-passfile=${passfile}" ];
          depends = [ device ];
        };

        systemd.services."gocryptfs-${baseNameOf name}" = {
          description = "gocryptfs mount ${name} (test reload)";
          wantedBy = [ "multi-user.target" ];
          reloadIfChanged = true;
          restartIfChanged = false;
          stopIfChanged = false;

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "mount-gocryptfs-${baseNameOf name}" ''
              if mountpoint -q "${name}"; then
                ${pkgs.fuse3}/bin/fusermount3 -uz "${name}" 2>/dev/null || true
              fi
              mkdir -p "${name}"
              ${pkgs.gocryptfs}/bin/gocryptfs -allow_other -passfile=${passfile} ${device}/crypt "${name}"
            '';
            ExecStop = "${pkgs.fuse3}/bin/fusermount3 -uz ${name}";
            ExecReload = pkgs.writeShellScript "reload-gocryptfs-${baseNameOf name}" ''
              ${pkgs.fuse3}/bin/fusermount3 -uz "${name}" 2>/dev/null || true
              ${pkgs.gocryptfs}/bin/gocryptfs -allow_other -passfile=${passfile} ${device}/crypt "${name}"
            '';
          };
        };
      };
    in lib.mkMerge [
      {
        networking = {
          hostName = "hvn-hyp1";
          hostId = "2f618214";
        };

        secretRequests = {
          "gocryptfs-media1" = {
            provider = "agenix";
            ageFile = inputs.self + "/.secrets/hosts/hvn-hyp1/gocryptfs-media1.age";
            mode = "0400";
            restartUnits = [ "gocryptfs-media1" ];
          };
          "gocryptfs-media2" = {
            provider = "agenix";
            ageFile = inputs.self + "/.secrets/hosts/hvn-hyp1/gocryptfs-media2.age";
            mode = "0400";
            restartUnits = [ "gocryptfs-media2" ];
          };
          "gocryptfs-media3" = {
            provider = "agenix";
            ageFile = inputs.self + "/.secrets/hosts/hvn-hyp1/gocryptfs-media3.age";
            mode = "0400";
            restartUnits = [ "gocryptfs-media3" ];
          };
        };

        boot.kernelParams = [
          "console=tty0"
          "random.trust_cpu=on"
          "random.trust_bootloader=on"
        ];

        boot.initrd.availableKernelModules = [ ];
        hardware.enableAllHardware = false;

        systemd.services."getty@tty1".enable = true;
        systemd.services."serial-getty@ttyS0".enable = true;

        environment.systemPackages = [ pkgs.gocryptfs ];

        deployment = {
          enable = true;
          target = "172.27.50.17";
          sshUser = "daniel";
          knownHostsPath = "modules/den/hosts/hvn-hyp1/known_hosts";
        };
      }

      (mkGocryptfsMount {
        name = "/mnt/storage-clear/media1";
        device = "/mnt/storage-crypt/media1";
        passfile = config.age.secrets."gocryptfs-media1".path;
      })

      (mkGocryptfsMount {
        name = "/mnt/storage-clear/media2";
        device = "/mnt/storage-crypt/media2";
        passfile = config.age.secrets."gocryptfs-media2".path;
      })

      (mkGocryptfsMount {
        name = "/mnt/storage-clear/media3";
        device = "/mnt/storage-crypt/media3";
        passfile = config.age.secrets."gocryptfs-media3".path;
      })
    ];
  };
}
