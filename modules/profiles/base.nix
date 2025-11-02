/**
  # Base Profile Aspect

  Minimal common configuration for all systems.
*/
{ self, ... }:
{
  flake.modules.nixos.profiles-base =
    { lib, pkgs, ... }:
    {
      imports =
        with self.modules.nixos;
        [
          # Hardware
          profiles-disks
          profiles-facter

          # Common
          profiles-time
          profiles-users

          # Networking
          profiles-networking
        ]
        ++ [
          self.modules.generic.nix-common
        ];

      # # systemd
      # systemd.additionalUpstreamSystemUnits = [
      #   "systemd-soft-reboot.service"
      #   "soft-reboot.target"
      # ];

      # Basic system packages
      environment.systemPackages = with pkgs; [
        # Monitoring / logs
        bottom
        lnav

        # Git is needed even for flakes
        git

        # htop
        # tree
      ];

      # Editing
      programs.vim = {
        enable = lib.mkDefault true;
        defaultEditor = lib.mkDefault true;
      };

      # Basic SSH configuration
      services.openssh = {
        enable = lib.mkDefault true;
        settings = {
          PermitRootLogin = lib.mkDefault "no";
          PasswordAuthentication = lib.mkDefault false;
        };
        hostKeys = lib.mkForce [ ];
        extraConfig = lib.mkAfter ''
          HostKey /persist/etc/ssh/ssh_host_ed25519_key
        '';
      };
    };

  flake.modules.darwin.profiles-base = {
    imports = [
      self.modules.generic.nix-common
    ];
  };

  # Future: homeManager profile can be added here
  # flake.modules.homeManager.profiles-base = { ... };
}
