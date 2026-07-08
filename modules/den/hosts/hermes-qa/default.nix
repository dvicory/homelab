# Hermes QA MicroVM — runs on hvn-hyp1 as a microvm guest. Used as a
# canary for prod deploys: the deploy service updates QA first, runs a
# canary check, then deploys to prod only if QA passes.
#
# microvm.isGuest = true triggers:
# - secretPath → .secrets/guests/hermes-qa/ (instead of .secrets/hosts/)
# - agenix battery uses /run/agenix/agenix-identity (from virtiofs) as
#   identityPaths instead of the host's SSH host key
# - The fleet instantiates this host normally (default intoAttr emits
#   nixosConfigurations.hermes-qa)
{ den, inputs, ... }: {
  den.hosts.x86_64-linux.hermes-qa = {
    environment = "prod";
    system-access-groups = [ "system-access" ];

    microvm.isGuest = true;

    networking.interfaces.dummy = {
      ipv4 = "10.27.50.21/24";
      gateway = "10.27.50.1";
    };

    settings = {
      services.hermes-microvm.agent = {
        model.default = "opencode-go/mimo-v2.5-pro";
        # Drain active conversations before restart (seconds)
        agent.restart_drain_timeout = 120;
      };
      services.hermes-microvm.dependencyGroups = [ "messaging" ];
      services.hermes-microvm.gitIdentity = {
        name = "Hermes QA Agent";
        email = "hermes-qa@localhost";
      };
    };
  };

  den.aspects.hermes-qa = {
    includes = with den.aspects; [
      disk.impermanence
      secrets.agenix
      core.security.openssh
      networking.default
      core.network.tailscale
      services.hermes-microvm
    ];

    nixos = { config, lib, pkgs, ... }: {
      imports = [ inputs.microvm.nixosModules.microvm ];

      networking.hostName = "hermes-qa";
      system.stateVersion = "26.05";

      microvm = {
        hypervisor = "cloud-hypervisor";
        guest.enable = true;
        optimize.enable = true;
        vcpu = 2;
        mem = 4096;

        vsock.cid = 3;
        vsock.ssh.enable = true;

        interfaces = [{
          id = "vm-hermes-qa";
          type = "tap";
          mac = "02:00:00:27:50:21";
        }];

        shares = [
          {
            tag = "ro-store";
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            proto = "virtiofs";
          }
          {
            tag = "persist";
            source = "/var/lib/microvms/hermes-qa/persist";
            mountPoint = "/persist";
            proto = "virtiofs";
            readOnly = false;
          }
          {
            # Delivers agenix-identity (decrypted by parent, symlinked by
            # the per-VM farm) to /run/agenix/runtime_host_key inside the VM.
            # The guest's agenix uses this as identityPaths to decrypt its
            # own secrets from the rekeyed files in the nix store.
            tag = "secrets";
            source = "/run/agenix-vm/hermes-qa";
            mountPoint = "/run/agenix";
            proto = "virtiofs";
            readOnly = true;
          }
        ];

        writableStoreOverlay = "/nix/.rw-store";
        volumes = [{
          image = "nix-store-overlay.img";
          mountPoint = "/nix/.rw-store";
          size = 4096;
          autoCreate = true;
        }];
        registerClosure = true;
      };

      # SSH host key — use default paths (/etc/ssh/ssh_host_*) so sshd-keygen
      # can write them through the impermanence symlink into the persist
      # virtiofs (writable). This avoids the read-only /run/agenix virtiofs
      # where the agenix identity key lives.
      services.openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "prohibit-password";
        };
      };

      # Explicitly place the authorized_keys in /etc/ssh/authorized_keys.d/
      # via environment.etc, which creates a Nix store symlink that survives
      # the tmpfs root filesystem (impermanence wipes ~/.ssh/).
      environment.etc."ssh/authorized_keys.d/daniel" = {
        mode = "0600";
        text = ''
          ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIItkbwb4903ks6RXq1AyRGRK3um1Wzo8tvo12lG9dete dvicory@mbp-2021-32gb
        '';
      };

      networking.firewall.allowedTCPPorts = [ 22 ];

      # Pass the vsock notify socket path on the kernel command line since
      # systemd can't read SMBIOS credentials with direct kernel boot.
      # This lets the guest send sd_notify("READY=1") over vsock so the
      # host systemd knows the VM has booted (instead of timing out).
      boot.kernelParams = [
        "systemd.set_credential=vmm.notify_socket:vsock-stream:2:8888"
      ];

      # Enable nix inside the VM for self-validation (nix eval, nix flake check)
      nix.enable = true;

      # The networking aspect generates matchConfig.Name from the entity's
      # interface attribute name, but we don't know the actual PCI slot
      # that cloud-hypervisor assigns. Override with a wildcard.
      systemd.network.networks."40-dummy".matchConfig.Name = lib.mkForce "en*";
    };
  };
}
