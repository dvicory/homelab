{ config, pkgs, ... }: {
  imports = [
    ../../profiles/server.nix
    ../../profiles/impermanence.nix
    ../../profiles/hypervisor.nix
  ];

  dlab.impermanence = {
    enable = true;
    persistPath = "/persist";
  };

  networking.hostId = "0b0a39da";

  sops.defaultSopsFile = ./secrets.yaml;
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
}
