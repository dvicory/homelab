{ self, ... }:
{
  flake.modules.nixos.hosts-builder =
    { config, lib, ... }:
    {
      imports = with self.modules.nixos; [
        profiles-server
        profiles-impermanence
        profiles-hypervisor
      ];

      config = {
        # Enable impermanence for proper system persistence
        dlab.impermanence = {
          enable = true;
          persistPath = "/persist";
        };

        # System identity
        networking.hostId = "0b0a39da"; # ZFS requires unique host ID

        # SOPS configuration (if using secrets)
        sops.defaultSopsFile = ./secrets.yaml;
        sops.age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];

        # Boot configuration for Apple Virtualization Framework (UTM)
        boot.kernelParams = [
          "console=tty0" # VGA console (for UTM graphical display)
          "console=hvc0" # Apple Virtualization Framework hypervisor console

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

        # GRUB configuration
        boot.loader.grub.configurationLimit = 8; # Limit boot entries to prevent /boot from filling

        # Enable getty on VGA console
        systemd.services."getty@tty1".enable = true;

        # Enable serial getty for Apple Virtualization Framework
        systemd.services."serial-getty@hvc0".enable = true;

        # Enable serial getty for fallback
        systemd.services."serial-getty@ttyS0".enable = true;
      };
    };
}
