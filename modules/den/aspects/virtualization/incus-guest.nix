{ den, inputs, ... }:
{
  den.aspects.virtualization.provides.incus-guest = {
    provides = {
      container = {
        includes = [ den.aspects.virtualization.incus-guest ];
        # system.build.images.lxc imports the native container module in its
        # image configuration, without adding image-only options to the node.
        nixos.boot.isContainer = true;
      };
      virtual-machine = {
        includes = [ den.aspects.virtualization.incus-guest ];
        nixos = {
          imports = [
            (inputs.nixpkgs + "/nixos/modules/virtualisation/incus-virtual-machine.nix")
          ];
          boot.isContainer = false;
        };
      };
    };

    nixos =
      {
        host,
        config,
        lib,
        pkgs,
        ...
      }:
      let
        platforms = den.aspects.virtualization.incus-guest.provides;
        selected = builtins.filter (name: host.hasAspect platforms.${name}) [
          "container"
          "virtual-machine"
        ];
        backend =
          assert lib.assertMsg (
            builtins.length selected == 1
          ) "Incus guests must select exactly one container or virtual-machine platform aspect.";
          builtins.head selected;
        isContainer = backend == "container";
        rootfs = config.system.build.images.lxc;
        metadata =
          if isContainer then config.system.build.images."lxc-metadata" else config.system.build.metadata;
        rootfsPath =
          if isContainer then
            "${rootfs.override { compressCommand = "pixz -0 -t"; }}/${rootfs.passthru.filePath}"
          else
            "${config.system.build.qemuImage}/nixos.qcow2";
        metadataPath =
          if isContainer then
            "${metadata}/${metadata.passthru.filePath}"
          else
            "${metadata}/${config.image.filePath}";
      in
      {
        assertions = [
          {
            assertion = config.boot.isContainer == isContainer;
            message = "Incus guest boot mode must match its selected platform aspect.";
          }
        ];
        hardware.enableAllHardware = false;
        # The native Incus VM image otherwise permits an empty root console password.
        users.users.root.initialHashedPassword = lib.mkIf (!isContainer) (lib.mkForce "!");
        networking.useHostResolvConf = false;

        services.openssh = {
          enable = true;
          startWhenNeeded = false;
          generateHostKeys = false;
          hostKeys = [
            {
              path = "/srv/identity/ssh_host_ed25519_key";
              type = "ed25519";
            }
          ];
          settings = {
            PermitRootLogin = "no";
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
          };
        };

        # The host stages this pair read-only. Never generate a replacement
        # identity when a mount is absent or its public key does not match.
        systemd.services.compute-ssh-host-key-check = {
          description = "Verify the staged compute guest SSH identity";
          requiredBy = [ "sshd.service" ];
          before = [ "sshd.service" ];
          # VM shares are mounted before the native agent signals readiness.
          requires = lib.optional (!isContainer) "incus-agent.service";
          after = lib.optional (!isContainer) "incus-agent.service";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = pkgs.writeShellScript "verify-compute-ssh-host-key" ''
              set -euo pipefail
              private=/srv/identity/ssh_host_ed25519_key
              public=/srv/identity/ssh_host_ed25519_key.pub
              test -s "$private"
              test -s "$public"
              actual="$(${pkgs.openssh}/bin/ssh-keygen -y -f "$private" | ${pkgs.coreutils}/bin/cut -d ' ' -f 1-2)"
              declared="$(${pkgs.coreutils}/bin/cut -d ' ' -f 1-2 "$public")"
              test "$actual" = "$declared"
            '';
          };
        };

        # The immutable image carries its platform, checked before deletion.
        system.build.computeBundle =
          assert lib.assertMsg (
            config.boot.isContainer == isContainer
          ) "Incus guest boot mode must match its selected platform aspect.";
          pkgs.linkFarm "${host.name}-bundle" [
            {
              name = "backend";
              path = pkgs.writeText "compute-backend" backend;
            }
            {
              name = "metadata.tar.xz";
              path = metadataPath;
            }
            {
              name = if isContainer then "rootfs.tar.xz" else "rootfs.qcow2";
              path = rootfsPath;
            }
            {
              name = "system";
              path =
                if isContainer then rootfs.passthru.config.system.build.toplevel else config.system.build.toplevel;
            }
          ];
      };
  };
}
