{ den, ... }: {
  den.hosts.aarch64-linux.builder = {
    environment = "dev";
    system-access-groups = [ "server-access" ];
    settings.core.nix.gc.enable = false;

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
      den.aspects.core.facter
      den.aspects.core.base
      den.aspects.disk.zfs
      den.aspects.disk.zfs.provides.pool
      den.aspects.disk.impermanence
      den.aspects.roles.server
      den.aspects.secrets.agenix
    ];

    nixos = { config, pkgs, ... }: {
      networking = {
        hostName = "builder";
        hostId = "0b0a39da";
      };

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
        knownHostsPath = "modules/den/hosts/builder/known_hosts";
      };
    };
  };
}
