{ den, ... }:
{
  den.hosts.x86_64-linux.compute-1 = {
    environment = "prod";
    system-access-groups = [ "server-access" ];
    settings.core.users.secrets.enable = false;
    networking.interfaces.eth0 = {
      dhcp = "yes";
      managed = false;
    };
  };

  den.aspects.compute-1 = {
    includes = [
      den.aspects.core.base
      den.aspects.core.security.openssh
      den.aspects.services.kubernetes
    ];

    nixos =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        rootfs = config.system.build.images.lxc;
        metadata = config.system.build.images."lxc-metadata";
        rootfsPath = "${rootfs}/${rootfs.passthru.filePath}";
        metadataPath = "${metadata}/${metadata.passthru.filePath}";
      in
      {
        boot.isContainer = true;
        hardware.enableAllHardware = false;
        networking.hostName = "compute-1";
        networking.useHostResolvConf = false;
        networking.firewall.allowedTCPPorts = [
          22
          6443
          30096
        ];
        programs.command-not-found.enable = lib.mkForce false;

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

        # The host stages this key pair read-only. A missing or mismatched pair
        # must stop sshd rather than trigger NixOS's key generator.
        systemd.services.compute-ssh-host-key-check = {
          description = "Verify the staged compute guest SSH identity";
          requiredBy = [ "sshd.service" ];
          before = [ "sshd.service" ];
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

        # Native LXC variants provide the two tarballs. The bundle records
        # their exact paths without copying them or building them on a host
        # that only evaluates this guest.
        system.build.computeBundle = pkgs.linkFarm "compute-1-bundle" [
          {
            name = "metadata.tar.xz";
            path = metadataPath;
          }
          {
            name = "rootfs.tar.xz";
            path = rootfsPath;
          }
          {
            name = "system";
            path = rootfs.passthru.config.system.build.toplevel;
          }
        ];

        # Guest management remains disabled until its independent host-key
        # trust is provisioned. The host/Incus path remains the recovery path.
        deployment = {
          enable = false;
          target = "10.210.0.10";
          sshUser = "daniel";
          knownHostsPath = null;
        };
      };
  };
}
