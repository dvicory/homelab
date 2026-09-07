{ den, inputs, ... }: {
  den.hosts.x86_64-linux.hvn-hyp1 = {
    environment = "prod";
    system-access-groups = [
      "server-access"
      "workload-access"
    ];

    settings = {
      core.nix.gc.enable = false;
      virtualization.compute = {
        project = "compute";
        instance = "compute-1";
        profile = "compute-1";
        pool = "incus-compute";
        network = "incus-compute";
        address = "10.210.0.10";
        idmapBase = 1000000;
        idmapSize = 65536;
        retainedPaths = {
          jellyfin-config = {
            path = "/var/lib/homelab/compute-1/jellyfin";
            guestPath = "/srv/jellyfin/config";
            uid = 751;
            gid = 751;
            mode = "0750";
          };
          immich-library = {
            path = "/var/lib/homelab/compute-1/platform/immich/library";
            guestPath = "/srv/platform/immich/library";
            uid = 1000;
            gid = 1000;
            mode = "0750";
          };
          immich-postgres = {
            path = "/var/lib/homelab/compute-1/platform/immich/postgres";
            guestPath = "/srv/platform/immich/postgres";
            uid = 999;
            gid = 999;
            mode = "0700";
          };
          radarr = {
            path = "/var/lib/homelab/compute-1/platform/media/radarr";
            guestPath = "/srv/platform/media/radarr";
            uid = 752;
            gid = 751;
            mode = "0750";
          };
          sonarr = {
            path = "/var/lib/homelab/compute-1/platform/media/sonarr";
            guestPath = "/srv/platform/media/sonarr";
            uid = 753;
            gid = 751;
            mode = "0750";
          };
          sabnzbd = {
            path = "/var/lib/homelab/compute-1/platform/media/sabnzbd";
            guestPath = "/srv/platform/media/sabnzbd";
            uid = 754;
            gid = 751;
            mode = "0750";
          };
          seerr = {
            path = "/var/lib/homelab/compute-1/platform/media/seerr";
            guestPath = "/srv/platform/media/seerr";
            uid = 1000;
            gid = 1000;
            mode = "0750";
          };
          media-data = {
            path = "/var/lib/homelab/compute-1/platform/media/data";
            guestPath = "/srv/platform/media/data";
            uid = 754;
            gid = 751;
            mode = "2770";
          };
          monitoring-prometheus = {
            path = "/var/lib/homelab/compute-1/platform/monitoring/prometheus";
            guestPath = "/srv/platform/monitoring/prometheus";
            uid = 65534;
            gid = 65534;
            mode = "0750";
          };
          monitoring-alertmanager = {
            path = "/var/lib/homelab/compute-1/platform/monitoring/alertmanager";
            guestPath = "/srv/platform/monitoring/alertmanager";
            uid = 65534;
            gid = 65534;
            mode = "0750";
          };
          monitoring-grafana = {
            path = "/var/lib/homelab/compute-1/platform/monitoring/grafana";
            guestPath = "/srv/platform/monitoring/grafana";
            uid = 472;
            gid = 472;
            mode = "0750";
          };
          monitoring-loki = {
            path = "/var/lib/homelab/compute-1/platform/monitoring/loki";
            guestPath = "/srv/platform/monitoring/loki";
            uid = 10001;
            gid = 10001;
            mode = "0750";
          };
          identity-kanidm = {
            path = "/var/lib/homelab/compute-1/platform/identity/kanidm";
            guestPath = "/srv/platform/identity/kanidm";
            uid = 1000;
            gid = 1000;
            mode = "0700";
          };
        };
        runtimeSecrets = {
          "immich--immich-runtime--DB_PASSWORD" = { namespace = "immich"; name = "immich-runtime"; key = "DB_PASSWORD"; };
          "media--media-runtime--RADARR_API_KEY" = { namespace = "media"; name = "media-runtime"; key = "RADARR_API_KEY"; };
          "media--media-runtime--SONARR_API_KEY" = { namespace = "media"; name = "media-runtime"; key = "SONARR_API_KEY"; };
          "media--media-runtime--SABNZBD_API_KEY" = { namespace = "media"; name = "media-runtime"; key = "SABNZBD_API_KEY"; };
          "media--media-runtime--SABNZBD_USERNAME" = { namespace = "media"; name = "media-runtime"; key = "SABNZBD_USERNAME"; };
          "media--media-runtime--SABNZBD_PASSWORD" = { namespace = "media"; name = "media-runtime"; key = "SABNZBD_PASSWORD"; };
          "media--media-runtime--JELLYFIN_OWNER_USERNAME" = { namespace = "media"; name = "media-runtime"; key = "JELLYFIN_OWNER_USERNAME"; };
          "media--media-runtime--JELLYFIN_OWNER_PASSWORD" = { namespace = "media"; name = "media-runtime"; key = "JELLYFIN_OWNER_PASSWORD"; };
          "media--media-runtime--JELLYFIN_OWNER_EMAIL" = { namespace = "media"; name = "media-runtime"; key = "JELLYFIN_OWNER_EMAIL"; };
          "identity--kanidm-provision--idm-admin-password" = { namespace = "identity"; name = "kanidm-provision"; key = "idm-admin-password"; };
          "gateway--gateway-tls--tls.crt" = { namespace = "gateway"; name = "gateway-tls"; key = "tls.crt"; type = "kubernetes.io/tls"; };
          "gateway--gateway-tls--tls.key" = { namespace = "gateway"; name = "gateway-tls"; key = "tls.key"; type = "kubernetes.io/tls"; };
          "gateway--gateway-tls--ca.crt" = { namespace = "gateway"; name = "gateway-tls"; key = "ca.crt"; type = "kubernetes.io/tls"; };
          "identity--kanidm-tls--tls.crt" = { namespace = "identity"; name = "kanidm-tls"; key = "tls.crt"; type = "kubernetes.io/tls"; };
          "identity--kanidm-tls--tls.key" = { namespace = "identity"; name = "kanidm-tls"; key = "tls.key"; type = "kubernetes.io/tls"; };
          "monitoring--grafana-admin--admin-user" = { namespace = "monitoring"; name = "grafana-admin"; key = "admin-user"; };
          "monitoring--grafana-admin--admin-password" = { namespace = "monitoring"; name = "grafana-admin"; key = "admin-password"; };
          "argocd--argocd-secret--admin.password" = { namespace = "argocd"; name = "argocd-secret"; key = "admin.password"; };
          "argocd--argocd-secret--admin.passwordMtime" = { namespace = "argocd"; name = "argocd-secret"; key = "admin.passwordMtime"; };
          "argocd--argocd-secret--server.secretkey" = { namespace = "argocd"; name = "argocd-secret"; key = "server.secretkey"; };
        };
        recoveryPath = "/var/lib/homelab/compute-1/recovery";
        identityPath = "/var/lib/homelab/compute-1/identity";
        mediaPath = "/run/homelab-compute/media";
        mediaSource = "/mnt/storage/media";
        config = {
          "boot.autostart" = "true";
          "limits.cpu" = "4";
          "limits.memory" = "8GiB";
          "limits.processes" = "8192";
          "security.guestapi" = "false";
          "raw.idmap" = "both 1000000-1065535 0-65535";
          "security.idmap.isolated" = "true";
          "security.nesting" = "true";
          "security.privileged" = "false";
        };
        devices = {
          root = {
            path = "/";
            pool = "incus-compute";
            type = "disk";
          };
          eth0 = {
            name = "eth0";
            network = "incus-compute";
            type = "nic";
            "ipv4.address" = "10.210.0.10";
            host_name = "veth-comp-1";
          };
          media = {
            path = "/srv/media";
            propagation = "rslave";
            # The host export is already recursively read-only. Incus 7.4
            # rejects readonly=true together with recursive=true.
            recursive = "true";
            required = "true";
            source = "/run/homelab-compute/media";
            type = "disk";
          };
          identity = {
            path = "/srv/identity";
            readonly = "true";
            required = "true";
            source = "/var/lib/homelab/compute-1/identity";
            type = "disk";
          };
        };
      };
      services.mergerfs.pools."/mnt/storage/media" = {
        branches = [
          "/mnt/storage-clear/media1"
          "/mnt/storage-clear/media2"
          "/mnt/storage-clear/media3"
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
          {
            fileSystems.${device} = {
              device = "/dev/disk/by-label/${baseNameOf device}";
              fsType = "btrfs";
              options = [ "noatime" ];
            };

            systemd.services."gocryptfs-${baseNameOf name}" = {
              description = "gocryptfs mount ${name}";
              wantedBy = [ "multi-user.target" ];
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
