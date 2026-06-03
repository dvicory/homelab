{ den, inputs, ... }: {
  den.hosts.x86_64-linux.hvn-hyp1 = {
    settings.core.nix.gc.enable = false;

    environment = "prod";
    users.daniel = {
      sshKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIItkbwb4903ks6RXq1AyRGRK3um1Wzo8tvo12lG9dete dvicory@mbp-2021-32gb"
      ];
      extraGroups = [ "wheel" ];
    };

    settings.services.mergerfs.pools."/mnt/storage/media" = {
      branches = [
        "/mnt/storage-clear/media1"
        "/mnt/storage-clear/media2"
        "/mnt/storage-clear/media3"
      ];
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
      den.batteries.hostname
      den.aspects.core.facter
      den.aspects.virtualization.incus
      den.aspects.disk.zfs
      den.aspects.disk.zfs.provides.pool
      den.aspects.disk.impermanence
      den.aspects.roles.server
      den.aspects.core."remote-unlock"
      den.aspects.services.mergerfs
    ];

    nixos = { config, pkgs, ... }: {
      networking = {
        hostName = "hvn-hyp1";
        hostId = "2f618214";
      };

      sops.age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];

      secretRequests = {
        "gocryptfs-media1" = {
          provider = "agenix";
          ageFile = inputs.self + "/.secrets/hosts/hvn-hyp1/gocryptfs-media1.age";
          mode = "0400";
        };
        "gocryptfs-media2" = {
          provider = "agenix";
          ageFile = inputs.self + "/.secrets/hosts/hvn-hyp1/gocryptfs-media2.age";
          mode = "0400";
        };
        "gocryptfs-media3" = {
          provider = "agenix";
          ageFile = inputs.self + "/.secrets/hosts/hvn-hyp1/gocryptfs-media3.age";
          mode = "0400";
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

      fileSystems."/mnt/storage-crypt/media1" = {
        device = "/dev/disk/by-label/media1";
        fsType = "btrfs";
        options = [ "noatime" ];
      };

      sops.secrets."hvn-hyp1/gocryptfs/media1" = {};

      fileSystems."/mnt/storage-clear/media1" = {
        device = "/mnt/storage-crypt/media1/crypt";
        fsType = "fuse.gocryptfs";
        options = [ "rw" "allow_other" "-passfile=${config.sops.secrets."hvn-hyp1/gocryptfs/media1".path}" ];
        depends = [ "/mnt/storage-crypt/media1" ];
      };

      fileSystems."/mnt/storage-crypt/media2" = {
        device = "/dev/disk/by-label/media2";
        fsType = "btrfs";
        options = [ "noatime" ];
      };

      sops.secrets."hvn-hyp1/gocryptfs/media2" = {};

      fileSystems."/mnt/storage-clear/media2" = {
        device = "/mnt/storage-crypt/media2/crypt";
        fsType = "fuse.gocryptfs";
        options = [ "rw" "allow_other" "-passfile=${config.sops.secrets."hvn-hyp1/gocryptfs/media2".path}" ];
        depends = [ "/mnt/storage-crypt/media2" ];
      };

      fileSystems."/mnt/storage-crypt/media3" = {
        device = "/dev/disk/by-label/media3";
        fsType = "btrfs";
        options = [ "noatime" ];
      };

      sops.secrets."hvn-hyp1/gocryptfs/media3" = {};

      fileSystems."/mnt/storage-clear/media3" = {
        device = "/mnt/storage-crypt/media3/crypt";
        fsType = "fuse.gocryptfs";
        options = [ "rw" "allow_other" "-passfile=${config.sops.secrets."hvn-hyp1/gocryptfs/media3".path}" ];
        depends = [ "/mnt/storage-crypt/media3" ];
      };

      deployment = {
        enable = true;
        target = "172.27.50.17";
        sshUser = "daniel";
        knownHostsPath = "modules/den/hosts/hvn-hyp1/known_hosts";
      };
    };
  };
}
