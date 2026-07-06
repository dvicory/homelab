# MicroVM host — enables microvm.host on the host machine, sets up a
# private bridge (br-microvm) with NAT for VM outbound connectivity, and
# declares the `microvm` class + `den.schema.host` extensions that guest
# entities use. Also provides a per-VM agenix symlink farm so each VM
# only sees its own secrets via virtiofs.
#
# Based on sini's microvm.nix but simplified:
# - No GPU passthrough (no _gpu-passthrough-lib.nix, no gpu-claims quirk)
# - No root key injection from user registry (use bridge SSH / Tailscale SSH)
# - Adds br-microvm bridge + NAT (sini uses a bridge on the LAN; we use a
#   private subnet behind NAT so VMs are not on the physical network)
# - Adds per-VM agenix symlink farm for secret isolation
{ inputs, lib, ... }: {
  den.aspects.virtualization.microvm-host = {
    nixos = { ... }: {
      imports = [ inputs.microvm.nixosModules.host ];

      microvm.host.enable = true;

      users.users.microvm.extraGroups = [ "disk" ];

      # Private bridge for MicroVMs — VMs are on 10.27.50.0/24, behind NAT.
      # They are NOT on the physical LAN.
      systemd.network = {
        enable = true;
        netdevs.br-microvm.netdevConfig = {
          Kind = "bridge";
          Name = "br-microvm";
        };
        networks.br-microvm = {
          matchConfig.Name = "br-microvm";
          addresses = [{ Address = "10.27.50.1/24"; }];
        };
        # Attach microvm tap interfaces to the bridge
        networks.microvm-tap = {
          matchConfig.Name = "vm-*";
          networkConfig.Bridge = "br-microvm";
        };
      };

      networking.nat = {
        enable = true;
        internalInterfaces = [ "br-microvm" ];
        externalInterface = "eno1";
      };
    };

    persist = [{
      directory = "/var/lib/microvms";
      user = "microvm";
      group = "kvm";
      mode = "0775";
    }];
  };

  # The `microvm` class lets guest aspects carry microvm submodule options
  # (e.g. microvm.pkgs) that the guest-resolver splices into microvm.vms.
  den.classes.microvm.description = "MicroVM guest configuration (microvm.nix options)";

  # Schema extensions on every host entity for declaring guests.
  den.schema.host.imports = [
    ({ ... }: {
      options.microvm.guests = lib.mkOption {
        type = lib.types.listOf lib.types.raw;
        default = [ ];
        defaultText = lib.literalExpression "[ ]";
        description = ''
          Guest MicroVMs to run on this host. List of den hosts, e.g.
          [ den.hosts.x86_64-linux.hermes-prod ].
        '';
      };
      options.microvm.sharedNixStore = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Auto-share the host nix store into guests over virtiofs.
        '';
      };
    })
  ];
}
