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
    system-access-groups = [ ];

    microvm.isGuest = true;

    networking.interfaces.eth0 = {
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

      # Static IP on the private bridge subnet
      systemd.network = {
        enable = true;
        networks."20-eth0" = {
          matchConfig.Name = "eth0";
          networkConfig = {
            Address = [ "10.27.50.21/24" ];
            Gateway = "10.27.50.1";
            DNS = [ "1.1.1.1" ];
            DHCP = "no";
          };
        };
      };

      # SSH host key — same keypair as the agenix identity (runtime_host_key,
      # delivered via virtiofs from the parent). Using one key for both
      # means migrating this guest to a standalone host is a file move, not
      # a key rotation. Stable across reboots despite impermanence.
      services.openssh = {
        enable = true;
        hostKeys = [{
          path = "/run/agenix/runtime_host_key";
          type = "ed25519";
        }];
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "prohibit-password";
        };
      };

      networking.firewall.allowedTCPPorts = [ 22 ];

      # Deterministic machine-id for stable Tailscale identity
      environment.etc."machine-id" = {
        mode = "0644";
        text = (builtins.hashString "md5" "hermes-qa") + "\n";
      };

      # Enable nix inside the VM for self-validation (nix eval, nix flake check)
      nix.enable = true;
    };
  };
}
