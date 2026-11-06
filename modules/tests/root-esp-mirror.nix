# Native disko installation, real Hoopsnake SSH unlock, and independent console
# recovery from encrypted mirrored ZFS. Headscale substitutes disposable preauth
# keys for OAuth; this does not exercise production OAuth or tailnet policy.
{
  config,
  den,
  lib,
  inputs,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      transport =
        let
          python = pkgs.python3.withPackages (p: [ p.pexpect ]);
          sshUnlock = pkgs.writeText "root-esp-ssh-unlock.py" ''
            import sys
            import pexpect

            passphrase = sys.stdin.readline().rstrip("\n")
            session = pexpect.spawn("${pkgs.openssh}/bin/ssh", [
                "-tt", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=root-esp-initrd",
                "-o", "UserKnownHostsFile=/root/fixture-known-hosts",
                "-i", "/root/fixture-authorized", "shell@" + sys.argv[1],
            ], encoding="utf-8", timeout=60)
            # Hoopsnake runs its configured diagnostic shell, not the SSH command
            # argument. Send the same native commands an operator enters in that shell.
            session.sendline("zfs get -H -o value keystatus rpool")
            session.expect_exact("\r\nunavailable\r\n")
            session.sendline("systemctl show --no-pager sysroot-var-lib-nixos.mount -p Requires -p After -p What; echo __MOUNT_GRAPH_DONE__")
            session.expect_exact("\r\n__MOUNT_GRAPH_DONE__\r\n")
            properties = dict(
                line.split("=", 1) for line in session.before.splitlines()
                if line.startswith(("Requires=", "After=", "What="))
            )
            assert properties["What"] == "/sysroot/persist/var/lib/nixos", properties
            for dependency in ["Requires", "After"]:
                assert "sysroot-persist.mount" in properties[dependency].split(), properties
            print("INITRD_BIND_GRAPH", properties)
            session.sendline("exec /bin/systemd-tty-ask-password-agent --query")
            session.expect("Enter key for rpool:")
            session.sendline(passphrase)
            session.expect(pexpect.EOF)
            session.close()
            print("Authorized SSH observed locked rpool and answered its native password request")
          '';
        in
        {
          meta.timeout = lib.mkForce 1200;
          nodes = {
            headscale = {
              virtualisation.memorySize = 512;
              networking.useDHCP = false;
              networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
                {
                  address = "192.168.1.1";
                  prefixLength = 24;
                }
              ];
              networking.firewall.allowedTCPPorts = [ 443 ];
              networking.firewall.allowedUDPPorts = [ 3478 ];
              systemd.services.fixture-tls = {
                requiredBy = [ "nginx.service" ];
                before = [ "nginx.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  User = "nginx";
                  Group = "nginx";
                  StateDirectory = "fixture-tls";
                  StateDirectoryMode = "0700";
                  UMask = "0077";
                };
                script = ''
                  ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
                    -keyout /var/lib/fixture-tls/key.pem -out /var/lib/fixture-tls/cert.pem \
                    -subj /CN=headscale -addext subjectAltName=IP:192.168.1.1
                '';
              };
              services.headscale = {
                enable = true;
                port = 8080;
                settings = {
                  server_url = "https://192.168.1.1";
                  dns = {
                    magic_dns = false;
                    override_local_dns = false;
                  };
                  derp = {
                    urls = [ ];
                    server = {
                      enabled = true;
                      region_id = 999;
                      stun_listen_addr = "0.0.0.0:3478";
                    };
                  };
                };
              };
              services.nginx = {
                enable = true;
                virtualHosts."192.168.1.1" = {
                  addSSL = true;
                  sslCertificate = "/var/lib/fixture-tls/cert.pem";
                  sslCertificateKey = "/var/lib/fixture-tls/key.pem";
                  locations."/" = {
                    proxyPass = "http://127.0.0.1:8080";
                    proxyWebsockets = true;
                  };
                };
              };
              environment.systemPackages = [ pkgs.headscale ];
            };
            client = {
              virtualisation.memorySize = 512;
              networking.useDHCP = false;
              networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
                {
                  address = "192.168.1.2";
                  prefixLength = 24;
                }
              ];
              services.tailscale.enable = true;
              systemd.services.tailscaled.environment.SSL_CERT_FILE = "/run/fixture-ca.pem";
              environment.systemPackages = [
                pkgs.openssh
                pkgs.netcat
                python
              ];
            };
          };
          # Extend disko's script rather than copying its installer implementation.
          testScript = lib.mkBefore ''
            import json
            import secrets
            import shlex
            import time
            from collections.abc import Callable

            native_create_machine = create_machine

            def create_machine(start_command, **kwargs):
                # Disko's dynamically created UEFI guests have no NIC by default. Join
                # the same isolated test VLAN as the declarative Headscale/client nodes.
                return native_create_machine(
                    start_command=start_command
                    + f" -netdev vde,id=fixture,sock={vlan1.socket_dir}"
                    + " -device virtio-net-pci,netdev=fixture,id=fixture-net,mac=52:54:00:12:01:03",
                    **kwargs,
                )

            def write_runtime(vm, path, value):
                vm.succeed(f"umask 077; printf %s {shlex.quote(value)} > {shlex.quote(path)}")

            headscale.start()
            client.start()
            headscale.wait_for_unit("headscale.service", timeout=60)
            headscale.wait_for_unit("nginx.service", timeout=60)
            headscale.wait_for_open_port(443, timeout=30)
            headscale.succeed("headscale users create fixture")
            # Headscale has no Tailscale OAuth client API. Disposable tagged preauth
            # keys exercise the actual tsnet/SSH/credential path, not OAuth issuance.
            auth_key = headscale.succeed("headscale preauthkeys -u 1 create --reusable --expiration 1h --tags tag:hoopsnake").strip()
            client_auth_key = headscale.succeed("headscale preauthkeys -u 1 create --expiration 1h").strip()
            ca = headscale.succeed("cat /var/lib/fixture-tls/cert.pem")
            client.wait_for_unit("multi-user.target")
            write_runtime(client, "/run/fixture-ca.pem", ca)
            client.succeed("systemctl restart tailscaled.service")
            client.succeed(f"tailscale up --login-server=https://192.168.1.1 --auth-key={shlex.quote(client_auth_key)} --hostname=unlock-client --accept-dns=false")
            client.succeed("umask 077; ssh-keygen -q -t ed25519 -N \"\" -f /root/fixture-authorized; ssh-keygen -q -t ed25519 -N \"\" -f /root/fixture-unauthorized")
            authorized_key = client.succeed("cat /root/fixture-authorized.pub")
            runtime_passphrase = secrets.token_urlsafe(32)

            def provision_unlock(vm):
                # Disko has finished its remount/idempotence checks with its disposable
                # installation key. Replace it before constructing any boot artifacts.
                write_runtime(vm, "/tmp/runtime-passphrase", runtime_passphrase)
                vm.succeed("zfs change-key -o keylocation=file:///tmp/runtime-passphrase rpool && zfs set keylocation=prompt rpool && rm /tmp/runtime-passphrase /tmp/root_passphrase /tmp/secret.key")
                write_runtime(vm, "/mnt/boot/authorized_keys", authorized_key)
                write_runtime(vm, "/mnt/boot/fixture-ca.pem", ca)
                write_runtime(vm, "/mnt/boot/hoopsnake-environment", f"TS_AUTHKEY={auth_key}\nTS_BASE_URL=https://192.168.1.1\n")
                host_key = vm.succeed("${pkgs.openssh}/bin/ssh-keygen -y -f /tmp/boot_host_key").strip()
                write_runtime(client, "/root/fixture-known-hosts", "root-esp-initrd " + host_key + "\n")
                vm.succeed("mkdir -p /mnt/persist/var/lib/fixture && printf persistent > /mnt/persist/var/lib/fixture/persistent-marker && printf dirty > /mnt/ephemeral-marker")

            def remote_unlock(vm):
                # Nixpkgs waits 60 import attempts before accepting a degraded pool.
                vm.wait_for_console_text("Enter key for rpool", timeout=120)
                deadline = time.monotonic() + 90
                address = None
                while time.monotonic() < deadline:
                    peers = json.loads(client.succeed("tailscale status --json")).get("Peer") or {}
                    current = [peer for peer in peers.values() if peer["HostName"] == "hoopsnake-root-esp-fixture" and peer.get("Online")]
                    if len(current) == 1:
                        address = current[0]["TailscaleIPs"][0]
                        break
                    time.sleep(1)
                assert address is not None, "initrd Hoopsnake did not join the disposable tailnet"
                client.wait_until_succeeds(f"nc -z -w 2 {address} 22", timeout=30)
                result, output = client.execute(
                    f"timeout 15 ssh -T -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes "
                    f"-o HostKeyAlias=root-esp-initrd -o UserKnownHostsFile=/root/fixture-known-hosts "
                    f"-i /root/fixture-unauthorized shell@{address} </dev/null 2>&1"
                )
                assert result != 0 and "Permission denied (publickey)" in output, output
                # The helper observes the *actual* locked keystatus after rejection,
                # then answers the native request whose consumer runs zfs load-key.
                client.log(client.succeed(f"printf '%s\\n' {shlex.quote(runtime_passphrase)} | ${python}/bin/python ${sshUnlock} {address}"))

            def assert_boot(vm, timeout=90):
                vm.wait_for_unit("multi-user.target", timeout=timeout)
                vm.succeed("test $(zfs get -H -o value keystatus rpool) = available && test $(zfs get -H -o value keylocation rpool) = prompt")
                vm.succeed("test ! -e /ephemeral-marker && test $(cat /var/lib/fixture/persistent-marker) = persistent && test $(cat /persist/var/lib/fixture/persistent-marker) = persistent")
                for unit, source in [
                    ("var-lib-nixos.mount", "/persist/var/lib/nixos"),
                    ("var-lib-fixture.mount", "/persist/var/lib/fixture"),
                ]:
                    graph = vm.succeed(f"systemctl show --no-pager {unit} -p Requires -p After -p What -p ActiveState")
                    properties = dict(line.split("=", 1) for line in graph.splitlines())
                    assert properties["ActiveState"] == "active", properties
                    target = source.removeprefix("/persist")
                    vm.succeed(f"findmnt --mountpoint {target}")
                    identities = vm.succeed(f"stat -c '%d:%i' {target} {source}").splitlines()
                    assert identities[0] == identities[1], (unit, identities)
                    for dependency in ["Requires", "After"]:
                        assert "persist.mount" in properties[dependency].split(), properties
                    vm.log(f"STAGE2_BIND_GRAPH {unit} {properties}")
                events = [
                    json.loads(line)
                    for line in vm.succeed("journalctl -b -o json --no-pager").splitlines()
                ]
                def completed(unit, job):
                    return [
                        int(event["__MONOTONIC_TIMESTAMP"]) for event in events
                        if event.get("UNIT") == unit
                        and event.get("JOB_TYPE") == job
                        and event.get("JOB_RESULT") == "done"
                    ]
                assert completed("initrd-zfs-rollback.service", "start"), "rollback did not complete"
                if completed("hoopsnake.service", "start"):
                    stopped = completed("hoopsnake.service", "stop")
                    switching = [
                        int(event["__MONOTONIC_TIMESTAMP"]) for event in events
                        if event.get("UNIT") == "initrd-switch-root.service"
                        and event.get("JOB_TYPE") == "start"
                    ]
                    assert stopped and switching and max(stopped) < min(switching), "Hoopsnake survived switch-root"
                vm.fail("pgrep -x hoopsnake")
                vm.fail(f"grep -aRF -- {shlex.quote(runtime_passphrase)} /boot")
                # Dirty this root again so every following cold boot must really roll
                # it back; persistence is deliberately selected, never root residue.
                vm.succeed("printf dirty > /ephemeral-marker; sync")
                # Discard the prior ephemeral server identity before the next cold boot.
                if vm.name != "offline_console_recovery":
                    peers = json.loads(headscale.succeed("headscale nodes list --output json"))
                    for peer in peers:
                        if peer.get("name") == "hoopsnake-root-esp-fixture":
                            headscale.succeed(f"headscale nodes delete --identifier {peer['id']} --force")
          '';
        };
      host = config.den.hosts.${system}.hvn-hyp1 // {
        disk.device = "/dev/vda";
        zfs.rootPool = {
          name = "rpool";
          disk1 = "/dev/vda";
          disk2 = "/dev/vdb";
        };
        zfs.swap.enable = false;
      };
      poolModule =
        (import ../den/aspects/disk/zfs/pool.nix {
          inherit lib self;
        }).den.aspects.disk.zfs.provides.pool.nixos;
      impermanenceModule =
        (import ../den/aspects/disk/impermanence.nix {
          inherit den lib inputs;
        }).den.aspects.disk.impermanence.nixos;
      fixture = import "${pkgs.path}/nixos/lib/eval-config.nix" {
        inherit system;
        modules = [
          ((import ../den/aspects/disk/default.nix { inherit lib inputs; }).den.aspects.disk.nixos { })
          inputs.disko-zfs.nixosModules.default
          ({ config, pkgs, ... }: poolModule { inherit host config pkgs; })
          ((import ../den/aspects/core/hoopsnake.nix { inherit inputs; }).den.aspects.core.hoopsnake.nixos {
            host.system = system;
          })
          (
            { config, pkgs, ... }:
            impermanenceModule {
              inherit config pkgs;
              inherit host;
            }
          )
          ({ config, pkgs, ... }: {
            system.stateVersion = "26.05";
            networking.hostName = "root-esp-fixture";
            networking.hostId = "acbd1234";
            boot.supportedFilesystems = [
              "vfat"
              "zfs"
            ];
            boot.zfs.forceImportRoot = false;
            networking.usePredictableInterfaceNames = false;
            networking.useDHCP = false;
            boot.initrd.network.enable = true;
            boot.initrd.systemd.network = {
              enable = true;
              networks."40-fixture" = {
                matchConfig.Name = "eth0";
                address = [ "192.168.1.3/24" ];
                networkConfig.DHCP = "no";
              };
            };
            boot.initrd.availableKernelModules = [
              "virtio_pci"
              "virtio_blk"
              "virtio_net"
            ];
            environment.persistence."/persist".directories = [
              "/var/lib/fixture"
              "/var/lib/nixos"
            ];
            assertions = [
              {
                assertion = lib.all (
                  source:
                  !(lib.elem (toString source) [
                    "/tmp/secret.key"
                    "/tmp/root_passphrase"
                    "/tmp/runtime-passphrase"
                  ])
                ) (lib.attrValues config.boot.initrd.secrets);
                message = "The encrypted-root fixture must not embed an installation or data key in its initrd.";
              }
            ];
            disko.devices.disk.root.content.partitions.ESP.content.postMountHook = lib.mkBefore ''
              umask 077
              test -e /tmp/boot_host_key || ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /tmp/boot_host_key
              cp /tmp/boot_host_key /tmp/runtime_host_key
              test -e /tmp/tailscale_client_secret || ${pkgs.openssl}/bin/openssl rand -hex 32 > /tmp/tailscale_client_secret
            '';
            disko.devices.zpool.rpool.preCreateHook = lib.mkBefore ''
              umask 077
              cp /tmp/secret.key /tmp/root_passphrase
            '';
            # Disko's native harness remounts after exporting the pool. Keep its
            # disposable file key until those installer checks have completed.
            disko.devices.zpool.rpool.postCreateHook = lib.mkForce "";
            boot.initrd.network.hoopsnake = {
              enable = true;
              ssh.authorizedKeysFile = "/boot/authorized_keys";
              systemd-credentials = {
                privateHostKey = {
                  file = "/boot/boot_host_key";
                  encrypted = false;
                };
                clientId = {
                  text = "headscale-preauth-fixture";
                  encrypted = false;
                };
                clientSecret = {
                  file = "/boot/tailscale_client_secret";
                  encrypted = false;
                };
              };
              tailscale = {
                name = "hoopsnake-root-esp-fixture";
                tags = [ "tag:hoopsnake" ];
                environmentFile = "/boot/hoopsnake-environment";
              };
            };
            boot.initrd.secrets."/etc/fixture-ca.pem" = "/boot/fixture-ca.pem";
            boot.initrd.systemd.services.hoopsnake.environment.SSL_CERT_FILE = "/etc/fixture-ca.pem";
            environment.systemPackages = [
              pkgs.rsync
              pkgs.util-linux
            ];
            # The configuration a running host has before it adopts the
            # mirror: /boot by partition label, no root-esp link.
            specialisation.legacy-boot.configuration = {
              fileSystems."/boot".device = lib.mkOverride 40 "/dev/disk/by-partlabel/disk-root-ESP";
              services.udev.extraRules = lib.mkForce "";
              systemd.services.root-esp-link.enable = lib.mkForce false;
            };
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
                options = [
                  "ro"
                  "trans=virtio"
                  "version=9p2000.L"
                  "cache=loose"
                ];
              };
              fileSystems."/nix/.rw-store" = {
                fsType = "tmpfs";
                neededForBoot = true;
                options = [ "mode=0755" ];
              };
            };
            disko.tests.bootCommands = ''
              remote_unlock(machine)
            '';
            disko.tests.extraChecks = ''
              def check_boot(vm, label):
                  assert_boot(vm)
                  vm.succeed(f"test $(readlink -f $(findmnt -nro SOURCE --mountpoint /boot)) = $(readlink -f /dev/disk/by-partlabel/{label})")
                  vm.succeed("test -s /boot/boot_host_key && test -s /boot/tailscale_client_secret && test -s /boot/hoopsnake-environment && test -s /boot/authorized_keys")
                  vm.succeed("NIXOS_INSTALL_BOOTLOADER=1 /run/current-system/bin/switch-to-configuration boot")
              assert_boot(machine)
              # The first installation ran before activation, with the mirror
              # deliberately absent from fstab and therefore unmounted.
              machine.succeed("mkdir /tmp/mirror; mount /dev/disk/by-partlabel/disk-root-mirror-ESP /tmp/mirror")
              machine.succeed("test -s /tmp/mirror/EFI/BOOT/BOOTX64.EFI && test -s /tmp/mirror/boot_host_key && test -s /tmp/mirror/tailscale_client_secret && test -s /tmp/mirror/hoopsnake-environment && test -s /tmp/mirror/authorized_keys && test -s /tmp/mirror/fixture-ca.pem && test -n \"$(find /tmp/mirror/loader/entries -name '*.conf' -print -quit)\"")
              machine.succeed("test -s /boot/loader/random-seed && test -s /tmp/mirror/loader/random-seed && if cmp -s /boot/loader/random-seed /tmp/mirror/loader/random-seed; then false; else test $? -eq 1; fi")
              machine.succeed("umount /tmp/mirror; echo updated > /boot/update-sentinel")
              machine.succeed("NIXOS_INSTALL_BOOTLOADER=1 /run/current-system/bin/switch-to-configuration boot")
              machine.succeed("mount /dev/disk/by-partlabel/disk-root-mirror-ESP /tmp/mirror && cmp /boot/update-sentinel /tmp/mirror/update-sentinel && umount /tmp/mirror")
              # A live switch from the pre-mirror configuration changes the
              # /boot device. Start from that state, without the link, and
              # require the switch to leave the primary ESP mounted at /boot.
              mirror_system = machine.succeed("readlink -f /run/current-system").strip()
              machine.succeed("/run/current-system/specialisation/legacy-boot/bin/switch-to-configuration test")
              # The mirror-aware initrd leaves udev claims on both ESPs.
              # Reload the legacy rules and retrigger both devices so udev
              # withdraws those claims before the old-to-new switch.
              machine.succeed("test $(systemctl show -p ActiveState --value root-esp-link.service) = inactive && udevadm control --reload && udevadm settle")
              machine.succeed("udevadm trigger --action=change --settle $(readlink -f /dev/disk/by-partlabel/disk-root-ESP) $(readlink -f /dev/disk/by-partlabel/disk-root-mirror-ESP)")
              machine.succeed("test ! -e /dev/disk/root-esp && test ! -L /dev/disk/root-esp")
              machine.succeed("test $(readlink -f $(findmnt -nro SOURCE --mountpoint /boot)) = $(readlink -f /dev/disk/by-partlabel/disk-root-ESP)")
              machine.succeed(f"{mirror_system}/bin/switch-to-configuration test")
              machine.succeed("test -L /dev/disk/root-esp")
              machine.succeed("test $(readlink -f $(findmnt -nro SOURCE --mountpoint /boot)) = $(readlink -f /dev/disk/by-partlabel/disk-root-ESP)")
              machine.succeed("test -s /boot/update-sentinel; test -s /boot/boot_host_key")
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
                  remote_unlock(survivor)
                  check_boot(survivor, label)
                  survivor.succeed("test $(zpool list -H -o health rpool) = DEGRADED")
                  survivor.shutdown()

              # A separate cold boot with both control-plane VMs powered off
              # and the target NIC disconnected before any unlock. Recovery
              # must finish without reconnecting it or restarting either peer.
              headscale.shutdown()
              client.shutdown()
              disks = survivor_disks
              recovery = create_test_machine(oldmachine=installer, name="offline_console_recovery")
              disks = original_disks
              started = time.monotonic()
              recovery.start()
              recovery.send_monitor_command("set_link fixture-net off")
              recovery.wait_for_console_text("Enter key for rpool", timeout=120)
              recovery.send_console(runtime_passphrase + "\n")
              assert_boot(recovery, timeout=150)
              recovery.succeed("test $(cat /sys/class/net/eth0/carrier) = 0")
              assert time.monotonic() - started < 180, "offline serial recovery exceeded 180 seconds"
              recovery.shutdown()
            '';
          })
        ];
      };
      baseTest = fixture._module.args.diskoLib.testLib.makeDiskoTest {
        inherit pkgs;
        inherit (fixture) extendModules;
        name = "root-esp-mirror";
        disko-config = builtins.removeAttrs fixture.config [ "_module" ];
        testMode = "direct";
        efi = true;
        # All private transport/bootstrap credentials and the final data key are
        # generated at runtime, after disko's existing installer checks.
        postDisko = ''
          installer = machine
          provision_unlock(machine)
        '';
        bootCommands = fixture.config.disko.tests.bootCommands;
        extraSystemConfig = fixture.config.disko.tests.extraConfig;
        extraTestScript = fixture.config.disko.tests.extraChecks;
      };
      # Keep disko's installer and disk/UEFI machinery intact. Its native test
      # derivation exposes the NixOS test extension API for additional peers.
      test = baseTest.extend {
        modules = [ transport ];
      };
    in
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        root-esp-mirror = test // {
          meta = test.meta // {
            hestia.group = "${system}-root-esp-mirror-runtime";
          };
        };
      };
    };
}
