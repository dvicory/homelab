{
  config,
  lib,
  self,
  ...
}:
{
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system) (
      let
        compute = config.den.hosts.x86_64-linux.hvn-hyp1.settings.virtualization.compute;
        jellyfinState = compute.retainedPaths.jellyfin-config;
        guest = self.nixosConfigurations.compute-1.extendModules {
          modules = [
            {
              nixpkgs.hostPlatform = lib.mkForce system;
              networking.hostName = lib.mkForce "sandbox-1";

              # This derived image is deliberately not the production guest:
              # there is no SSH trust or runtime-secret watcher in the sandbox.
              services.openssh.enable = lib.mkForce false;
              services.openssh.startWhenNeeded = lib.mkForce false;
              systemd.services.compute-ssh-host-key-check.enable = lib.mkForce false;
              systemd.services.kubernetes-runtime-secrets.enable = lib.mkForce false;
              systemd.paths.kubernetes-runtime-secrets.enable = lib.mkForce false;

              networking.nameservers = lib.mkForce [ ];
              services.resolved.enable = lib.mkForce false;
              nix.settings = {
                substituters = lib.mkForce [ ];
                fallback = lib.mkForce false;
              };
              networking.firewall.allowedTCPPorts = lib.mkForce [ 30096 ];
              networking.firewall.allowedUDPPorts = lib.mkForce [ ];

              # The guest owns its static address; no DHCP server is needed.
              systemd.network.networks."40-eth0" = {
                address = lib.mkForce [ "10.211.0.10/24" ];
                gateway = lib.mkForce [ ];
                networkConfig.DHCP = lib.mkForce "no";
                networkConfig.IPv6AcceptRA = lib.mkForce false;
              };

              services.k3s.extraFlags = lib.mkForce [
                "--snapshotter=native"
                "--node-ip=10.211.0.10"
                "--advertise-address=10.211.0.10"
                "--flannel-iface=eth0"
              ];

              systemd.tmpfiles.rules = [
                "d /srv/media 0755 root root -"
                "d /srv/state 0755 root root -"
              ];
            }
          ];
        };
        rootfs = guest.config.system.build.images.lxc;
        metadata = guest.config.system.build.images."lxc-metadata";
        rootfsPath = "${rootfs}/${rootfs.passthru.filePath}";
        metadataPath = "${metadata}/${metadata.passthru.filePath}";
        image = self.packages.${system}.jellyfin-image;
        imageTag = lib.last (lib.splitString ":" image.imageReference);
        environment =
          (self.nixidyEnvs.${system}.prod-home.override (old: {
            modules = old.modules ++ [
              {
                applications.jellyfin-retained.resources.persistentVolumes.jellyfin-config.spec = {
                  capacity.storage = lib.mkForce "2Gi";
                  local.path = lib.mkForce "/srv/state/jellyfin-config";
                  nodeAffinity.required.nodeSelectorTerms = lib.mkForce [
                    {
                      matchExpressions = [
                        {
                          key = "kubernetes.io/hostname";
                          operator = "In";
                          values = [ "sandbox-1" ];
                        }
                      ];
                    }
                  ];
                };
                applications.jellyfin-retained.resources.persistentVolumeClaims.jellyfin-config.spec.resources.requests.storage =
                  lib.mkForce "2Gi";

                applications.jellyfin.helm.releases.jellyfin.values = {
                  defaultPodOptions = {
                    nodeSelector."kubernetes.io/hostname" = lib.mkForce "sandbox-1";
                    securityContext.runAsUser = lib.mkForce jellyfinState.uid;
                    securityContext.runAsGroup = lib.mkForce jellyfinState.gid;
                    securityContext.runAsNonRoot = lib.mkForce true;
                  };
                  controllers.main = {
                    initContainers.prepare.image = {
                      tag = lib.mkForce imageTag;
                      pullPolicy = lib.mkForce "Never";
                    };
                    containers.main = {
                      image = {
                        tag = lib.mkForce imageTag;
                        pullPolicy = lib.mkForce "Never";
                      };
                      env.JELLYFIN_PublishedServerUrl = lib.mkForce "http://127.0.0.1:18096";
                    };
                  };
                  persistence.media.hostPath = lib.mkForce "/srv/media";
                  persistence.media.globalMounts = lib.mkForce [
                    {
                      path = "/media";
                      readOnly = true;
                      mountPropagation = "HostToContainer";
                    }
                  ];
                  service.main = {
                    type = lib.mkForce "NodePort";
                    ports.http.nodePort = lib.mkForce 30096;
                  };
                };
              }
            ];
          })).config;
        manifests = pkgs.writeText "jellyfin-sandbox-manifests.yaml" (
          builtins.toJSON {
            apiVersion = "v1";
            kind = "List";
            items =
              environment.applications.jellyfin-retained.objects ++ environment.applications.jellyfin.objects;
          }
        );
        profile = pkgs.writeText "jellyfin-sandbox-profile.yaml" ''
          description: Unprivileged offline Jellyfin sandbox
          config:
            boot.autostart: "false"
            limits.cpu: "4"
            limits.memory: 4GiB
            limits.processes: "4096"
            raw.idmap: "both 1000751 751"
            security.guestapi: "false"
            security.idmap.isolated: "true"
            security.nesting: "true"
            security.privileged: "false"
          devices:
            root:
              path: /
              pool: homelab-sandbox
              type: disk
            eth0:
              name: eth0
              network: hl-sandbox0
              type: nic
            media:
              path: /srv/media/data
              propagation: rslave
              readonly: "true"
              required: "true"
              source: /srv/homelab-sandbox/media
              type: disk
            state:
              path: /srv/state/jellyfin-config
              propagation: rprivate
              required: "true"
              source: /srv/homelab-sandbox/state/jellyfin-config
              type: disk
            proxy:
              bind: host
              connect: "tcp:10.211.0.10:30096"
              listen: "tcp:127.0.0.1:18096"
              type: proxy
        '';
        firewall = pkgs.writeText "jellyfin-sandbox-firewall.nft" ''
          table inet sandbox-isolation {
            chain input {
              type filter hook input priority -50; policy accept;
              iifname "hl-sandbox0" ct state { established, related } accept
              iifname "hl-sandbox0" drop
            }

            chain forward {
              type filter hook forward priority -50; policy accept;
              iifname "hl-sandbox0" drop
              oifname "hl-sandbox0" drop
            }
          }
        '';
        sample =
          pkgs.runCommand "jellyfin-sandbox-sample.mp4"
            {
              nativeBuildInputs = [ pkgs.ffmpeg ];
            }
            ''
              ffmpeg -hide_banner -loglevel error \
                -f lavfi -i color=c=black:s=320x180:r=30 \
                -t 5 -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
                -y "$out"
            '';
      in
      {
        packages.jellyfin-sandbox-bundle = pkgs.linkFarm "jellyfin-sandbox-bundle" [
          {
            name = "guest/metadata.tar.xz";
            path = metadataPath;
          }
          {
            name = "guest/rootfs.tar.xz";
            path = rootfsPath;
          }
          {
            name = "jellyfin-image.tar";
            path = image;
          }
          {
            name = "manifests.yaml";
            path = manifests;
          }
          {
            name = "profile.yaml";
            path = profile;
          }
          {
            name = "firewall.nft";
            path = firewall;
          }
          {
            name = "sample.mp4";
            path = sample;
          }
          {
            name = "README.md";
            path = self + "/docs/jellyfin-sandbox.md";
          }
        ];
      }
    );
}
