{ den, ... }: {
  den.hosts.aarch64-linux.builder = {
    settings.core.nix.gc.enable = false;

    users.daniel = {
      sshKeys = [ ../../../hosts/builder/ssh.pub ];
      extraGroups = [ "wheel" ];
    };

    zfs = {
      rootPool = {
        name = "root";
        disk1 = "/dev/vda";
      };
      swap.enable = true;
    };

    networking.interfaces.enp0s1 = {
      ipv4 = "192.168.65.90/24";
      dhcp = true;
      initrd.enable = true;
    };
  };

  den.aspects.builder = {
    includes = [
      den.batteries.hostname
      den.aspects."dlab/profile/facter"
      den.aspects."dlab/profile/disks"
      den.aspects."dlab/profile/impermanence"
      den.aspects."dlab/profile/server"
    ];

    nixos = { config, pkgs, ... }: {
      networking = {
        hostName = "builder";
        hostId = "0b0a39da";
      };

      sops.age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];

      boot.kernelParams = [
        "console=tty0"
        "console=hvc0"
        "random.trust_cpu=on"
        "random.trust_bootloader=on"
      ];

      boot.initrd.availableKernelModules = [ ];
      hardware.enableAllHardware = false;

      systemd.services."getty@tty1".enable = true;
      systemd.services."serial-getty@hvc0".enable = true;
      systemd.services."serial-getty@ttyS0".enable = true;

      deployment = {
        enable = true;
        target = "192.168.65.75";
        sshUser = "daniel";
        knownHostsPath = "modules/hosts/builder/known_hosts";
      };
    };
  };
}
