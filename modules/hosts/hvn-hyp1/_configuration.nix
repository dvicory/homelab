{ config, pkgs, ... }:
let
  contracts = config._contracts;
in
{
  imports = [
    ../../profiles/server.nix
    ../../profiles/impermanence.nix
    ../../profiles/hypervisor.nix
  ];

  dlab = {
    impermanence = {
      enable = true;
    };

    diskConfig.swap = {
      enable = true;
      size = "16G";
    };
  };

  networking.hostId = "2f618214";

  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];

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
      "/mnt/storage-clear/media3"
    ];
  };
}
