{
  den,
  inputs,
  lib,
  ...
}:
{
  den.hosts.x86_64-linux.hvn-hyp1 = {
    environment = "prod";
    system-access-groups = [
      "server-access"
      "workload-access"
    ];

    settings = {
      core.nix.gc.enable = false;
      virtualization.compute = rec {
        stateRoot = "/var/lib/homelab/compute-1/state";
        address = "10.210.0.10";
        pool = "incus-compute";
        network = "incus-compute";
        idmapBase = 1000000;
        idmapSize = 65536;
        identityPath = "/var/lib/homelab/compute-1/identity";
        project = "compute";
        instance = "compute-1";
        profile = "compute-1";
        retainedPaths = { };
        runtimeSecrets = { };
        storageCapabilities = [ ];
        instanceConfig = {
          "boot.autostart" = "true";
          "limits.cpu" = "4";
          "limits.memory" = "12GiB";
          "limits.processes" = "8192";
          "security.guestapi" = "false";
          "security.idmap.isolated" = "true";
          "security.nesting" = "true";
          "security.privileged" = "false";
        };
        devices = {
          root = {
            path = "/";
            inherit pool;
            type = "disk";
          };
          eth0 = {
            name = "eth0";
            inherit network;
            type = "nic";
            "ipv4.address" = address;
            host_name = "veth-comp-1";
          };
          identity = {
            path = "/srv/identity";
            readonly = "true";
            required = "true";
            source = identityPath;
            type = "disk";
          };
        };
      };
      services.storage-roots.roots.media = {
        path = "/srv/media";
        user = "root";
        group = "media";
        mode = "2770";
      };
      services.mergerfs.pools."/srv/media/data".branches = [
        {
          path = "/mnt/storage-clear/media1";
          unit = "gocryptfs-media1.service";
        }
        {
          path = "/mnt/storage-clear/media2";
          unit = "gocryptfs-media2.service";
        }
        {
          path = "/mnt/storage-clear/media3";
          unit = "gocryptfs-media3.service";
        }
      ];
      services.hermes.agent = {
        model.default = "opencode-go/mimo-v2.5-pro";
      };
      services.hermes.dependencyGroups = [ "messaging" ];
      workloads.hermes.deploy = {
        enable = true;
        # Enable only after required CI and main branch protection are live.
        polling.enable = false;
      };
      disk.luks-storage.disks.media4 = {
        # Media4 is the empty new LUKS2/XFS destination. This declaration is
        # not evidence that physical work ran. Keep provisioned = false while
        # the wrapper's read-only preflight records direct media1 provenance,
        # source bytes, target capacity, stable by-id identity, and target
        # emptiness. Any MANUAL, failed, or conflicting probe stops.
        # Separately approve format, XFS/key/header recovery, and the direct
        # mount. Then quiesce writers, create source-bound quiescence evidence,
        # and separately approve the verified copy from the direct media1 tree
        # while media4 remains outside mergerfs. Never evacuate or wipe a
        # media4 partition and never put key material in commands or evidence.
        # Revision A later sets provisioned = true; Revision B changes only
        # the mergerfs branch from media1 to media4. Keep media1 mounted and
        # unchanged for rollback until a later explicit media1-format approval.
        device = "/dev/disk/by-id/wwn-0x5000cca27061f6b4-part1";
        mountpoint = "/mnt/storage-clear/media4";
        fsType = "xfs";
        provisioned = true;
      };
    };

    zfs = {
      rootPool = {
        name = "rpool";
        disk1 = "/dev/nvme0n1";
      };
      swap.enable = true;
    };

    networking.interfaces.eno1 = {
      ipv4 = "172.27.50.17/24";
      gateway = "172.27.50.1";
      initrd.enable = true;
    };
  };

  den.aspects.hvn-hyp1 = {
    includes = [
      den.aspects.core.facter
      den.aspects.core.base
      den.aspects.virtualization.incus
      den.aspects.virtualization.compute
      den.aspects.disk.zfs
      den.aspects.disk.zfs.provides.pool
      den.aspects.disk.impermanence
      den.aspects.disk.luks-storage
      den.aspects.roles.server
      den.aspects.core."remote-unlock"
      den.aspects.services.mergerfs
      den.aspects.services.storage-roots
      den.aspects.services.kubernetes-runtime-secrets
      den.aspects.services.media-namespace
      den.aspects.secrets.agenix
      den.aspects.core.network.tailscale
      den.aspects.services.hermes
      den.aspects.workloads.hermes.deploy
    ];

    nixos =
      {
        config,
        pkgs,
        lib,
        ...
      }:
      let
        mkGocryptfsMount =
          {
            name,
            device,
            passfile,
          }:
          {
            fileSystems.${device} = {
              device = "/dev/disk/by-label/${baseNameOf device}";
              fsType = "btrfs";
              options = [ "noatime" ];
            };

            systemd.services."gocryptfs-${baseNameOf name}" = {
              description = "gocryptfs mount ${name}";
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                Type = "simple";
                Restart = "on-failure";
                RestartSec = "5s";
                ExecStartPre = pkgs.writeShellScript "prepare-gocryptfs-${baseNameOf name}" ''
                  if ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg name}; then
                    ${pkgs.fuse3}/bin/fusermount3 -uz ${lib.escapeShellArg name}
                  fi
                  ${pkgs.coreutils}/bin/install -d ${lib.escapeShellArg name}
                '';
                ExecStart = "${pkgs.gocryptfs}/bin/gocryptfs -fg -allow_other -passfile=${passfile} ${lib.escapeShellArg "${device}/crypt"} ${lib.escapeShellArg name}";
                ExecStartPost = pkgs.writeShellScript "wait-gocryptfs-${baseNameOf name}" ''
                  for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
                    ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg name} && exit 0
                    ${pkgs.coreutils}/bin/sleep 0.1
                  done
                  echo "gocryptfs mount did not become ready: ${name}" >&2
                  exit 1
                '';
                ExecStop = "${pkgs.fuse3}/bin/fusermount3 -uz ${lib.escapeShellArg name}";
              };
            };
          };
      in
      lib.mkMerge [
        {
          networking = {
            hostName = "hvn-hyp1";
            hostId = "2f618214";
          };

          secretRequests = {
            "gocryptfs-media1" = {
              provider = "agenix";
              ageFile = inputs.self + "/.secrets/hosts/hvn-hyp1/gocryptfs-media1.age";
              mode = "0400";
              restartUnits = [ "gocryptfs-media1" ];
            };
            "gocryptfs-media2" = {
              provider = "agenix";
              ageFile = inputs.self + "/.secrets/hosts/hvn-hyp1/gocryptfs-media2.age";
              mode = "0400";
              restartUnits = [ "gocryptfs-media2" ];
            };
            "gocryptfs-media3" = {
              provider = "agenix";
              ageFile = inputs.self + "/.secrets/hosts/hvn-hyp1/gocryptfs-media3.age";
              mode = "0400";
              restartUnits = [ "gocryptfs-media3" ];
            };
          };

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

          deployment = {
            enable = true;
            target = "172.27.50.17";
            sshUser = "daniel";
            knownHostsPath = "modules/den/hosts/hvn-hyp1/known_hosts";
          };
        }

        (mkGocryptfsMount {
          name = "/mnt/storage-clear/media1";
          device = "/mnt/storage-crypt/media1";
          passfile = config.age.secrets."gocryptfs-media1".path;
        })

        (mkGocryptfsMount {
          name = "/mnt/storage-clear/media2";
          device = "/mnt/storage-crypt/media2";
          passfile = config.age.secrets."gocryptfs-media2".path;
        })

        (mkGocryptfsMount {
          name = "/mnt/storage-clear/media3";
          device = "/mnt/storage-crypt/media3";
          passfile = config.age.secrets."gocryptfs-media3".path;
        })
      ];
  };
}
