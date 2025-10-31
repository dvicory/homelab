{ self, inputs, ... }:
{
  flake-file.inputs = {
    hoopsnake.url = "github:boinkor-net/hoopsnake";
    hoopsnake.inputs.nixpkgs.follows = "nixpkgs";
    hoopsnake.inputs.flake-parts.follows = "flake-parts";
  };

  flake.modules.nixos.profiles-remote-unlock-tailscale =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (config.dlab) hostName hostCfg;
      inherit (self.packages.${pkgs.system}) initrdTailscaleUnlock;
    in
    {
      imports = [
        inputs.hoopsnake.nixosModules.default
      ];

      config = {
        boot.initrd = {
          network = {
            enable = true;
          };
          systemd = {
            enable = true;
            network.enable = true;
            network.networks = self.lib.dlab.hostToSystemdNetwork hostName;
            extraBin = {
              ping = "${pkgs.iputils}/bin/ping";
              trip = "${pkgs.trippy}/bin/trip";
              ip = "${pkgs.iproute2}/bin/ip";
              vi = "${pkgs.vim}/bin/vi";
            };

            emergencyAccess = true;
          };
        };

        # TODO keep around for debugging
        environment.systemPackages = [
          inputs.hoopsnake.packages.${pkgs.system}.hoopsnake
        ];

        boot.initrd.network.hoopsnake = {
          enable = true;
          systemd-credentials = {
            # TODO: use proper secret management
            privateHostKey.file = "/boot/boot_host_key";
            privateHostKey.encrypted = false;

            clientId.text = "kXUenK1hK411CNTRL";
            clientId.encrypted = false;
            # TODO: we need to figure out proper secret management for this
            # it's tricky because it needs to be available in initrd
            clientSecret.file = "/boot/tailscale_client_secret";
            clientSecret.encrypted = false;
          };
          ssh = {
            # TODO: we should lookup a special user or group for remote unlock keys
            authorizedKeysFile = pkgs.writeText "authorized_keys" (
              lib.concatStringsSep "\n" (
                self.lib.dlab.sshKeysForUser "daniel" config.dlab.hostName self.dlab.hosts
              )
            );
          };

          tailscale = {
            name = "hoopsnake-${hostName}";
            tags = [ "tag:hoopsnake" ];
            tsnetVerbose = true;
            cleanup = {
              deleteExisting = true;
              maxNodeAge = "10s";
            };
          };
        };
      };
    };
}
