{ self, ... }:
{
  flake.dlab.hosts = {
    hvn-hyp1 = {
      system = "x86_64-linux";
      tags = [
        "home"
        "hypervisor"
      ];
      networks = {
        homelan = {
          interfaces = {
            eno1 = {
              ipv4 = "172.27.50.17";
              # dhcp = true;
              initrd.enable = true;
            };
          };
        };
      };

      rootPool = {
        name = "rpool";
        disk1 = "/dev/nvme0n1";
      };

      users.daniel = {
        sshKeys = [ ./ssh.pub ];
      };

      deploy = {
        target = "172.27.50.17";
        user = "daniel";
        knownHostsPath = "modules/hosts/hvn-hyp1/known_hosts";
        bootHostKeyPath = "modules/hosts/hvn-hyp1/boot_host_key";
        runtimeHostKeyPath = "modules/hosts/hvn-hyp1/runtime_host_key";
      };

      secrets = {
        hostSopsFile = "modules/hosts/hvn-hyp1/secrets.yaml";
        sharedSopsFile = "shared/secrets.yaml";
      };
    };
  };

  flake.modules.nixos.hosts-hvn-hyp1 =
    { config, pkgs, ... }:
    let
      contracts = config._contracts;
    in
    {
      imports = with self.modules.nixos; [
        profiles-server
        profiles-impermanence
        profiles-hypervisor
      ];

      config = {
        dlab = {
          impermanence = {
            enable = true;
          };

          diskConfig.swap = {
            enable = true;
            size = "16G";
          };
        };

        # System identity
        networking.hostId = "2f618214";

        # SOPS configuration (if using secrets)
        sops.defaultSopsFile = ./secrets.yaml;
        sops.age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];

        # Boot configuration for Apple Virtualization Framework (UTM)
        boot.kernelParams = [
          "console=tty0" # VGA console (for UTM graphical display)

          # Proven-working RNG parameters:
          "random.trust_cpu=on"
          "random.trust_bootloader=on"
        ];

        # Hardware drivers configuration
        boot.initrd.availableKernelModules = [
          # Add specific drivers here if needed
          # Example: "r8169"  # Realtek network driver
        ];
        hardware.enableAllHardware = false;

        # Enable getty on VGA console
        systemd.services."getty@tty1".enable = true;

        # Enable serial getty for fallback
        systemd.services."serial-getty@ttyS0".enable = true;

        # Media filesystem
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
          options = [
            "rw"
            "allow_other"
            "-passfile=${config.sops.secrets."hvn-hyp1/gocryptfs/media1".path}"
          ];
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
          options = [
            "rw"
            "allow_other"
            "-passfile=${config.sops.secrets."hvn-hyp1/gocryptfs/media2".path}"
          ];
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
          options = [
            "rw"
            "allow_other"
            "-passfile=${config.sops.secrets."hvn-hyp1/gocryptfs/media3".path}"
          ];
          depends = [ "/mnt/storage-crypt/media3" ];
        };

        dlab.storage.mergerfs."/mnt/storage/media" = {
          branches = [
            "/mnt/storage-clear/media1"
            # "/mnt/storage-clear/media2"
            "/mnt/storage-clear/media3"
            # "/mnt/storage-clear/media-non-existent" # test non-existent branch
          ];
        };
      };
    };
}
