{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        # Production's exact package set, independent of the candidate root.
        baseline = import ./_security-baseline.nix { inherit system; };
        selected = inputs.self.nixosConfigurations.hvn-hyp1.config.virtualisation.incus;
        identity = package: client: ui: {
          package = toString package;
          client = toString client;
          ui = toString ui;
          daemon_version = lib.removeSuffix ".0" package.version;
          client_version = lib.removeSuffix ".0" client.version;
        };
        busybox = pkgs.busybox;
        closure = pkgs.closureInfo { rootPaths = [ busybox ]; };
        image = pkgs.runCommand "incus-security-image.tar.gz" { } ''
          mkdir -p image/rootfs/{bin,sbin,dev,proc,sys,tmp,etc,nix/store}
          cp -a $(cat ${closure}/store-paths) image/rootfs/nix/store/
          ln -s ${busybox}/bin/busybox image/rootfs/bin/sh
          ln -s ${busybox}/bin/busybox image/rootfs/bin/cat
          printf '#!${busybox}/bin/sh\nexec ${busybox}/bin/sleep 2147483647\n' > image/rootfs/sbin/init
          chmod 0755 image/rootfs/sbin/init
          printf 'architecture: x86_64\ncreation_date: 1\nproperties:\n  description: security recovery fixture\n' > image/metadata.yaml
          tar -C image --owner=0 --group=0 --numeric-owner -czf $out metadata.yaml rootfs
        '';
        test = pkgs.testers.runNixOSTest {
          name = "incus-security-runtime";
          globalTimeout = 20 * 60;
          requiredFeatures.kvm = true;
          nodes.machine = {
            system.stateVersion = "26.05";
            networking.nftables.enable = true;
            virtualisation = {
              cores = 2;
              memorySize = 1536;
              diskSize = 4096;
              restrictNetwork = true;
              incus = {
                enable = true;
                package = baseline.incus;
                clientPackage = baseline.incus.client;
                ui.enable = true;
                ui.package = baseline.incus-ui-canonical;
                preseed = {
                  config."core.https_address" = "127.0.0.1:8443";
                  storage_pools = [
                    {
                      name = "default";
                      driver = "dir";
                      config.source = "/var/lib/incus-storage-pools/fixture";
                    }
                  ];
                  profiles = [
                    {
                      name = "default";
                      devices.root = {
                        path = "/";
                        pool = "default";
                        type = "disk";
                      };
                    }
                  ];
                };
              };
            };
            systemd.tmpfiles.rules = [
              "d /var/lib/incus-storage-pools/fixture 0755 root root -"
            ];
            environment.systemPackages = [
              pkgs.curl
              pkgs.jq
              pkgs.openssl
            ];
            specialisation.security-update.configuration.virtualisation.incus = {
              package = lib.mkForce selected.package;
              clientPackage = lib.mkForce selected.clientPackage;
              ui.package = lib.mkForce selected.ui.package;
            };
          };
          testScript = ''
            import json
            image = "${image}"
            baseline_identity = json.loads(${
              builtins.toJSON (
                builtins.toJSON (identity baseline.incus baseline.incus.client baseline.incus-ui-canonical)
              )
            })
            selected_identity = json.loads(${
              builtins.toJSON (
                builtins.toJSON (identity selected.package selected.clientPackage selected.ui.package)
              )
            })
            ${builtins.readFile ./incus-security-runtime.py}
          '';
        };
      in
      {
        checks.incus-security-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-incus-runtime";
          };
        };
      }
    );
}
