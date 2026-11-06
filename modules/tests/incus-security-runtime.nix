{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        selected = inputs.self.nixosConfigurations.hvn-hyp1.config.virtualisation.incus;
        # Freeze the stock production-root baseline, not the moving candidate pkgs.incus.
        # This is an ordinary source import, never a module imported from a derivation.
        oldSource = builtins.fetchTree {
          type = "tarball";
          url = "https://releases.nixos.org/nixos/unstable/nixos-26.11pre1067334.801bef6abd86/nixexprs.tar.xz";
          narHash = "sha256-/Mz6ovEL+KZ9b0UkWEBd/DtmODXuXW3FhNnuGQYghvg=";
        };
        oldPkgs = import oldSource.outPath { inherit system; };
        oldPackage = oldPkgs.incus;
        # Incus release binaries report major.minor, while Nixpkgs records .0 too.
        identity = package: client: ui: {
          package = "${package}";
          client = "${client}";
          ui = "${ui}";
          package_version = package.version;
          client_package_version = client.version;
          daemon_version = lib.versions.majorMinor package.version;
          client_version = lib.versions.majorMinor client.version;
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
        test =
          assert lib.assertMsg (
            oldPackage.version == "7.4.0"
          ) "Incus cold-restore baseline must remain stock 7.4.0 from root 801bef6";
          assert lib.assertMsg (
            selected.package.version == "7.6.0"
          ) "Incus upgrade fixture requires the production-selected 7.6.0 candidate (root 1d060)";
          assert lib.assertMsg (
            oldPackage.client.version == oldPackage.version
          ) "Incus baseline client must match the frozen daemon";
          assert lib.assertMsg (
            selected.clientPackage.version == selected.package.version
          ) "Incus production client must match the selected daemon";
          pkgs.testers.runNixOSTest {
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
                  package = oldPackage;
                  clientPackage = oldPackage.client;
                  ui = {
                    enable = true;
                    package = oldPkgs.incus-ui-canonical;
                  };
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
              # Use the actual production selection, including its adjacent-ID-map
              # and client completion fixes; never replace it with stock pkgs.incus.
              specialisation.security-update.configuration.virtualisation.incus = {
                package = lib.mkForce selected.package;
                clientPackage = lib.mkForce selected.clientPackage;
                ui.package = lib.mkForce selected.ui.package;
              };
            };
            testScript = ''
              image = "${image}"
              baseline = ${builtins.toJSON (identity oldPackage oldPackage.client oldPkgs.incus-ui-canonical)}
              candidate = ${
                builtins.toJSON (identity selected.package selected.clientPackage selected.ui.package)
              }
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
