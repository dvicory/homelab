{
  den,
  inputs,
  config,
  lib,
  ...
}:
let
  clusterResources = config.flake.clusterResources.prod-home;
in
{
  den.hosts.x86_64-linux.hvn-hyp1 = {
    environment = "prod";
    system-access-groups = [
      "server-access"
      "workload-access"
    ];

    settings = {
      core.nix.gc.enable = false;
      virtualization.compute =
        { config, ... }:
        {
          config = {
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
            retainedPaths = lib.mapAttrs (
              name: entry:
              entry
              // {
                path = "${config.stateRoot}/${name}";
                guestPath = "/srv/state/${name}";
              }
            ) clusterResources.retainedPaths;
            runtimeSecrets = clusterResources.runtimeSecrets;
            storageCapabilities = [ "media" ];
            config = {
              "boot.autostart" = "true";
              "limits.cpu" = "4";
              "limits.memory" = "12GiB";
              "limits.processes" = "8192";
              "security.guestapi" = "false";
              # raw.idmap is derived from storageCapabilities: the ordinary
              # contiguous shift for everything, with an identity mapping for
              # each declared capability GID.
              "security.idmap.isolated" = "true";
              "security.nesting" = "true";
              "security.privileged" = "false";
            };
            devices = {
              root = {
                path = "/";
                inherit (config) pool;
                type = "disk";
              };
              eth0 = {
                name = "eth0";
                inherit (config) network;
                type = "nic";
                "ipv4.address" = config.address;
                host_name = "veth-comp-1";
              };
              media = {
                path = "/srv/media";
                propagation = "rslave";
                # Application-only storage must not gate the compute
                # environment: Incus skips this device when the source is
                # absent, and lifecycle preflight does not require it. The
                # unmounted pool root stays mode 0000, so an absent pool can
                # never present a writable substitute directory; workload
                # mounts fail closed until the pool (re)appears, and rslave
                # propagation carries a restored pool into the running guest.
                required = "false";
                source = "/srv/media";
                type = "disk";
              };
              identity = {
                path = "/srv/identity";
                readonly = "true";
                required = "true";
                source = config.identityPath;
                type = "disk";
              };
            };
          };
        };
      services.mergerfs.pools."/srv/media" = {
        branches = [
          "/mnt/storage-clear/media1"
          "/mnt/storage-clear/media2"
          "/mnt/storage-clear/media3"
        ];
        depends = [
          "gocryptfs-media1.service"
          "gocryptfs-media2.service"
          "gocryptfs-media3.service"
        ];
      };
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
        # Provisioning sequence (two deploys):
        #   1. On the workstation, with this config committed at
        #      provisioned = false, run:
        #        agenix generate
        #        agenix rekey
        #        git add .secrets/ && git commit
        #      Deploy. The agenix secret materializes at
        #      /run/agenix/luks-media4-key on the host.
        #   2. On the host, after attaching the disk:
        #        nix run .#prepare-luks-storage -- wwn-0x5000cca27061f6b4
        #      Then follow the recipe printed by the script (creates
        #      the filesystem, adds the agenix key as a LUKS keyslot).
        #   3. Flip provisioned = true, commit, redeploy. The crypttab
        #      row and fileSystems entry appear; the disk mounts at
        #      every subsequent boot.
        device = "/dev/disk/by-id/wwn-0x5000cca27061f6b4-part1";
        mountpoint = "/mnt/storage-clear/media4";
        fsType = "btrfs";
        provisioned = false;
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
      den.aspects.services.media-namespace
      den.aspects.services.storage-roots
      den.aspects.services.kubernetes-runtime-secrets
      den.aspects.disk.zfs
      den.aspects.disk.zfs.provides.pool
      den.aspects.disk.impermanence
      den.aspects.disk.luks-storage
      den.aspects.roles.server
      den.aspects.core."remote-unlock"
      den.aspects.services.mergerfs
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
          let
            backingUnit = lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" device) + ".mount";
          in
          {
            fileSystems.${device} = {
              device = "/dev/disk/by-label/${baseNameOf device}";
              fsType = "btrfs";
              options = [ "noatime" ];
            };

            # A bare branch mountpoint must never look usable: tmpfiles owns
            # it root:root 0000, and only a successful gocryptfs mount makes
            # it accessible. The pool's branch guard then refuses unmounted
            # branches instead of serving a smaller pool.
            systemd.tmpfiles.rules = [ "d ${name} 0000 root root -" ];

            systemd.services."gocryptfs-${baseNameOf name}" = {
              description = "gocryptfs mount ${name}";
              wantedBy = [ "multi-user.target" ];
              after = [ backingUnit ];
              bindsTo = [ backingUnit ];
              reloadIfChanged = true;
              restartIfChanged = false;
              stopIfChanged = false;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = pkgs.writeShellScript "mount-gocryptfs-${baseNameOf name}" ''
                  if mountpoint -q "${name}"; then
                    ${pkgs.fuse3}/bin/fusermount3 -uz "${name}" 2>/dev/null || true
                  fi
                  mkdir -p "${name}"
                  ${pkgs.gocryptfs}/bin/gocryptfs -allow_other -passfile=${passfile} ${device}/crypt "${name}"
                '';
                ExecStop = "${pkgs.fuse3}/bin/fusermount3 -uz ${name}";
                ExecReload = pkgs.writeShellScript "reload-gocryptfs-${baseNameOf name}" ''
                  ${pkgs.fuse3}/bin/fusermount3 -uz "${name}" 2>/dev/null || true
                  ${pkgs.gocryptfs}/bin/gocryptfs -allow_other -passfile=${passfile} ${device}/crypt "${name}"
                '';
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
