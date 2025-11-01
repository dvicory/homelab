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
    { config, ... }:
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
      };
    };
}
