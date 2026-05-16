{ den, ... }: {
  den.hosts.x86_64-linux.testvm.users.daniel = {
    extraGroups = [ "wheel" ];
  };

  den.aspects.testvm = {
    includes = [
      den.batteries.hostname
    ];

    nixos = { ... }: {
      networking.hostName = "testvm";

      fileSystems."/" = {
        device = "/dev/vda";
        fsType = "ext4";
      };

      boot.loader.grub.devices = [ "/dev/vda" ];
    };
  };
}
