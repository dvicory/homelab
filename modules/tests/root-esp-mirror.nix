# Native disko installation plus UEFI boots from each surviving encrypted-ZFS
# member. Credentials are disposable; this checks the pre-unlock credential
# boundary, not external Tailscale OAuth or production Hoopsnake connectivity.
{ lib, inputs, self, ... }:
{
  perSystem = { pkgs, system, ... }:
    let
      host = {
        disk.device = "/dev/vda";
        zfs.rootPool = {
          name = "rpool";
          disk1 = "/dev/vda";
          disk2 = "/dev/vdb";
        };
        zfs.swap.enable = false;
      };
      poolModule = (import ../den/aspects/disk/zfs/pool.nix {
        inherit lib self;
      }).den.aspects.disk.zfs.provides.pool.nixos;
      fixture = import "${pkgs.path}/nixos/lib/eval-config.nix" {
        inherit system;
        modules = [
          ((import ../den/aspects/disk/default.nix { inherit lib inputs; }).den.aspects.disk.nixos {})
          inputs.disko-zfs.nixosModules.default
          ({ config, pkgs, ... }: poolModule { inherit host config pkgs; })
          ({ config, pkgs, ... }: {
            system.stateVersion = "26.05";
            networking.hostName = "root-esp-fixture";
            networking.hostId = "acbd1234";
            boot.supportedFilesystems = [ "vfat" "zfs" ];
            boot.zfs.forceImportRoot = false;
            boot.initrd.systemd.enable = true;
            boot.initrd.systemd.storePaths = [ "${pkgs.openssh}/bin/ssh-keygen" ];
            boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" ];
            disko.devices.disk.root.content.partitions.ESP.content.postMountHook = lib.mkBefore ''
              test -e /tmp/boot_host_key || ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /tmp/boot_host_key
              cp /tmp/boot_host_key /tmp/runtime_host_key
              printf '%s' disposable-client-secret > /tmp/tailscale_client_secret
            '';
            disko.devices.zpool.rpool.preCreateHook = lib.mkBefore ''
              cp /tmp/secret.key /tmp/root_passphrase
            '';
            # Disko's native harness remounts after exporting the pool. Keep its
            # disposable file key until those installer checks have completed.
            disko.devices.zpool.rpool.postCreateHook = lib.mkForce "";
            # The same paths and native LoadCredential mechanism used by the
            # pinned Hoopsnake module; no data-decryption key in these files.
            boot.initrd.secrets = {
              "/etc/hoopsnake/privateHostKey" = "/boot/boot_host_key";
              "/etc/hoopsnake/clientSecret" = "/boot/tailscale_client_secret";
            };
            boot.initrd.systemd.services.root-esp-credentials = {
              requiredBy = [ "initrd.target" ];
              # Match Hoopsnake: LoadCredential needs the copied initrd secrets.
              after = [ "initrd-nixos-copy-secrets.service" ];
              before = [ "zfs-import-rpool.service" ];
              unitConfig.DefaultDependencies = false;
              serviceConfig = {
                Type = "oneshot";
                LoadCredential = [
                  "privateHostKey:/etc/hoopsnake/privateHostKey"
                  "clientSecret:/etc/hoopsnake/clientSecret"
                ];
                StandardOutput = "journal+console";
              };
              script = ''
                ${pkgs.openssh}/bin/ssh-keygen -y -f "$CREDENTIALS_DIRECTORY/privateHostKey" > /dev/null
                test "$(cat "$CREDENTIALS_DIRECTORY/clientSecret")" = disposable-client-secret
                echo ROOT_ESP_CREDENTIALS_READY
              '';
            };
            environment.systemPackages = [ pkgs.rsync pkgs.util-linux ];
            # Disko shares /nix/store directly over 9p. Real post-boot Nix
            # commands need the native QEMU writable-store overlay, not writes
            # to the host share or a disabled ownership check.
            disko.tests.extraConfig = {
              fileSystems."/nix/store" = lib.mkOverride 40 {
                neededForBoot = true;
                overlay = {
                  lowerdir = [ "/nix/.ro-store" ];
                  upperdir = "/nix/.rw-store/upper";
                  workdir = "/nix/.rw-store/work";
                };
              };
              fileSystems."/nix/.ro-store" = {
                device = "nix-store";
                fsType = "9p";
                neededForBoot = true;
                options = [ "ro" "trans=virtio" "version=9p2000.L" "cache=loose" ];
              };
              fileSystems."/nix/.rw-store" = {
                fsType = "tmpfs";
                neededForBoot = true;
                options = [ "mode=0755" ];
              };
            };
            # Match passphrase input to the serial console used by the prompt wait.
            disko.tests.bootCommands = ''
              machine.wait_for_console_text("ROOT_ESP_CREDENTIALS_READY")
              machine.wait_for_console_text("Enter key for rpool")
              machine.send_console("secretsecret\n")
            '';
            disko.tests.extraChecks = ''
              from collections.abc import Callable

              def check_boot(vm, label):
                  vm.wait_for_console_text("ROOT_ESP_CREDENTIALS_READY")
                  vm.wait_for_console_text("Enter key for rpool")
                  vm.send_console("secretsecret\n")
                  vm.wait_for_unit("multi-user.target")
                  vm.succeed("test $(zfs get -H -o value keystatus rpool) = available")
                  vm.succeed(f"test $(readlink -f $(findmnt -nro SOURCE --mountpoint /boot)) = $(readlink -f /dev/disk/by-partlabel/{label})")
                  vm.succeed("test -s /boot/boot_host_key; test -s /boot/tailscale_client_secret")
                  vm.succeed("NIXOS_INSTALL_BOOTLOADER=1 /run/current-system/bin/switch-to-configuration boot")

              machine.wait_for_unit("multi-user.target")
              # The first installation ran before activation, with the mirror
              # deliberately absent from fstab and therefore unmounted.
              machine.succeed("mkdir /tmp/mirror; mount /dev/disk/by-partlabel/disk-root-mirror-ESP /tmp/mirror")
              machine.succeed("test -s /tmp/mirror/EFI/BOOT/BOOTX64.EFI; test -s /tmp/mirror/boot_host_key; test -s /tmp/mirror/tailscale_client_secret; test -n \"$(find /tmp/mirror/loader/entries -name '*.conf' -print -quit)\"")
              machine.succeed("test -s /boot/loader/random-seed && test -s /tmp/mirror/loader/random-seed && if cmp -s /boot/loader/random-seed /tmp/mirror/loader/random-seed; then false; else test $? -eq 1; fi")
              machine.succeed("umount /tmp/mirror; echo updated > /boot/update-sentinel")
              machine.succeed("NIXOS_INSTALL_BOOTLOADER=1 /run/current-system/bin/switch-to-configuration boot")
              machine.succeed("mount /dev/disk/by-partlabel/disk-root-mirror-ESP /tmp/mirror; cmp /boot/update-sentinel /tmp/mirror/update-sentinel; umount /tmp/mirror")
              # A mounted but unrelated source must fail before any mirror copy.
              machine.succeed("mount -t tmpfs tmpfs /boot")
              machine.fail("${pkgs.writeShellScript "root-esp-sync" config.boot.loader.systemd-boot.extraInstallCommands}")
              machine.succeed("umount /boot")
              machine.shutdown()

              original_disks = disks
              # Keep original disk contents and identifiers; omit one physical
              # drive entirely, rather than deleting a mount or failing a unit.
              for index, label in [(1, "disk-root-mirror-ESP"), (0, "disk-root-ESP")]:
                  def survivor_disks(oldmachine, num_disks):
                      return ["-drive", f"file={oldmachine.state_dir}/empty{index}.qcow2,id=survivor,if=none,werror=report", "-device", "virtio-blk-pci,drive=survivor"]
                  disks: Callable[[object, int], list[str]] = survivor_disks
                  survivor = create_test_machine(oldmachine=installer, name=f"survivor_{index}")
                  disks = original_disks
                  survivor.start()
                  check_boot(survivor, label)
                  survivor.succeed("test $(zpool list -H -o health rpool) = DEGRADED")
                  survivor.shutdown()
            '';
          })
        ];
      };
      test = fixture._module.args.diskoLib.testLib.makeDiskoTest {
        inherit pkgs;
        inherit (fixture) extendModules;
        name = "root-esp-mirror";
        disko-config = builtins.removeAttrs fixture.config [ "_module" ];
        testMode = "direct";
        efi = true;
        # From here onward the on-disk pool has the production prompt boundary,
        # before bootloader installation and all full/degraded UEFI boots.
        postDisko = ''
          installer = machine
          machine.succeed("zfs set keylocation=prompt rpool")
        '';
        bootCommands = fixture.config.disko.tests.bootCommands;
        extraSystemConfig = fixture.config.disko.tests.extraConfig;
        extraTestScript = fixture.config.disko.tests.extraChecks;
      };
    in {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        root-esp-mirror = test // {
          meta = test.meta // { hestia.group = "${system}-root-esp-mirror-runtime"; };
        };
      };
    };
}
