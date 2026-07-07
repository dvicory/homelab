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
# - Declares agenix-identity secret requests for each guest (the bootstrap
#   secret that lets the guest decrypt its own secrets)
{ inputs, lib, ... }: {
  den.aspects.virtualization.microvm-host = {
    nixos = { config, host, pkgs, ... }: let
      # Build the list of guest names from the host entity's microvm.guests
      guestNames = map (g: g.name) host.microvm.guests;
    in {
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

      # Declare the guest's identity keypair secret on the parent.
      # This is the bootstrap: encrypted to the PARENT's key, decrypted
      # by the parent, delivered to the guest via virtiofs. The guest uses
      # it as both its agenix identity (identityPaths) and SSH host key.
      #
      # The ssh-key generator produces an ed25519 keypair — the private key
      # goes into runtime_host_key.age, the public key is written as
      # runtime_host_key.pub alongside it. agenix-rekey reads that .pub to
      # know which key to rekey the guest's other secrets to. Same filename
      # as real hosts — migrating a guest to a standalone host is a file move.
      secretRequests = lib.listToAttrs (map (guestName: lib.nameValuePair
        "${guestName}-runtime-host-key"
        {
          provider = "agenix";
          ageFile = inputs.self + "/.secrets/guests/${guestName}/runtime_host_key.age";
          mode = "0400";
          generator.script = "ssh-key";
        }
      ) guestNames);

      # Per-VM agenix symlink farm: creates /run/agenix-vm/<vm-name>/
      # with a symlink to the guest's runtime_host_key (decrypted by the
      # parent). The guest's virtiofs "secrets" share delivers this to
      # /run/agenix/runtime_host_key inside the VM, where the guest's
      # agenix uses it as identityPaths and openssh uses it as the host key.
      systemd.services.agenix-vm-secrets = {
        description = "Create per-VM agenix symlink farms";
        after = [ "agenix.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${lib.concatMapStrings (guestName: ''
            mkdir -p /run/agenix-vm/${guestName}
            if [ -f /run/agenix/${guestName}-runtime-host-key ]; then
              ln -sfn /run/agenix/${guestName}-runtime-host-key /run/agenix-vm/${guestName}/runtime_host_key
            fi
          '') guestNames}
        '';
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
      options.microvm.isGuest = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Marks this host as a MicroVM guest. When true:
          - secretPath overrides to .secrets/guests/<name>/ instead of
            .secrets/hosts/<name>/
          - The agenix battery uses /run/agenix/runtime_host_key (delivered
            via virtiofs from the parent) as identityPaths instead of the
            host's SSH host key
          - runtime_host_key serves as both the agenix identity and the
            SSH host key (same as real hosts, just delivered via virtiofs
            instead of persistent /etc/ssh/)
        '';
      };
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
