{ inputs, lib, ... }:
{
  # Reused from Homelab revision 2bf3f3a862360ae17cac95410f9ee53af1d5a2af.
  # A component-only migration: both generations use this flake's root pkgs.
  # Remote enrollment/CAPI and production identities are deliberately excluded.
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        rootPkgs = pkgs;
        oldComponent = builtins.fetchTree {
          type = "github";
          owner = "dvicory";
          repo = "nixpkgs";
          rev = "98dbf12cb2bb49c47f82bbdb4a6a3190792bdb00";
          narHash = "sha256-Ssrb+imztb6EX+aNSQkyL9AGBRZFilDFH7nfs7h2ts8=";
        };
        oldHomelab = builtins.fetchTree {
          type = "github";
          owner = "dvicory";
          repo = "homelab";
          rev = "90920bac376c6640478c1c45feaf6afa2c1c3900";
          narHash = "sha256-2KHmKX0smBDl3Pk554o30z44RxN2sAP1yX5gPvImSBM=";
        };
        # The historical aspect alone needs its historical input name. It is
        # not an alias in the production flake or an independently copied module.
        oldAspect =
          (import "${oldHomelab}/modules/den/aspects/services/security/crowdsec.nix" {
            inputs = {
              self = ./.;
              crowdsec-pr = oldComponent;
            };
          }).den.aspects.services.security.crowdsec;
        newAspect =
          (import ../den/aspects/services/security/crowdsec.nix {
            inputs = inputs // {
              self = ./.;
            };
          }).den.aspects.services.security.crowdsec;
        python = pkgs.python3.withPackages (p: [ p.pyyaml ]);

        generation =
          { upgraded, protectConsole }:
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            aspect = if upgraded then newAspect else oldAspect;
            marker = if upgraded then "fixture-new-%H-%m-%%" else "fixture-old";
          in
          {
            imports = [
              "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
              "${inputs.nixpkgs}/nixos/modules/testing/test-instrumentation.nix"
              aspect.nixos
              aspect.provides.bouncer.nixos
            ];
            disabledModules = [
              "services/security/crowdsec"
              "services/security/crowdsec.nix"
              "services/security/crowdsec-firewall-bouncer.nix"
            ];
            # Only the option boundary consumed by the real aspect, not agenix
            # host realization, decryption, rekeying, or a fake enrollment key.
            options = {
              secretRequests = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
              age.secrets = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
            };
            config = lib.mkMerge [
              {
                nixpkgs.pkgs = lib.mkForce rootPkgs;
                system.stateVersion = "26.05";
                system.name = "fixture";
                secretRequests.crowdsec-enrollmentKey.ageFile = lib.mkForce ./crowdsec-upgrade.nix;
                age.secrets.crowdsec-enrollmentKey.path = "/run/fixture-enrollment-disabled";
                networking = {
                  hostName = lib.mkForce "crowdsec-fixture";
                  useDHCP = false;
                  interfaces.eth1.ipv4.addresses = lib.mkForce [
                    {
                      address = "192.168.1.10";
                      prefixLength = 24;
                    }
                  ];
                  nftables.enable = true;
                  firewall.allowedTCPPorts = [ 8088 ];
                };
                virtualisation = {
                  cores = 2;
                  memorySize = 2048;
                  # No root disk: / is tmpfs on every boot. Only this separate
                  # block device survives shutdown/start, including SQLite WALs.
                  diskImage = null;
                  emptyDiskImages = [
                    {
                      size = 2048;
                      driveConfig.deviceExtraOpts.serial = "crowdsec-persist";
                    }
                  ];
                  fileSystems."/persist" = {
                    device = "/dev/disk/by-id/virtio-crowdsec-persist";
                    fsType = "ext4";
                    autoFormat = true;
                    neededForBoot = true;
                  };
                };
                users.users.crowdsec.uid = 661;
                users.groups.crowdsec.gid = 661;
                environment.systemPackages = [
                  pkgs.curl
                  pkgs.jq
                  pkgs.nftables
                  pkgs.sqlite
                  python
                ];
                services = {
                  openssh.enable = true;
                  # The upstream, embedded-content hub and data files exercise
                  # real cscli setup without depending on Internet availability.
                  caddy = {
                    enable = true;
                    virtualHosts = {
                      "http://127.0.0.1".extraConfig = ''
                        handle_path /nixos-test/* {
                          root * ${inputs.crowdsec}/nixos/tests/crowdsec/data/hub
                          file_server
                        }
                        handle_path /geolite/* {
                          root * ${inputs.crowdsec}/nixos/tests/crowdsec/data/geolite
                          file_server
                        }
                        handle_path /cloudflare/* {
                          root * ${inputs.crowdsec}/nixos/tests/crowdsec/data/cloudflare
                          file_server
                        }
                      '';
                      "http://:8088".extraConfig = ''respond "crowdsec-protected"'';
                    };
                  };
                  crowdsec = {
                    enable = true;
                    autoUpdateService = lib.mkForce false;
                    settings = {
                      console.enrollKeyFile = lib.mkForce null;
                      config = {
                        api.server.online_client.credentials_path = lib.mkForce null;
                        cscli = {
                          hub_branch = "nixos-test";
                          __hub_url_template__ = "http://127.0.0.1/%s/%s";
                        };
                      };
                      profiles = [
                        {
                          name = marker;
                          filters = [ "false" ];
                          decisions = [
                            {
                              type = "ban";
                              duration = "12h";
                            }
                          ];
                        }
                      ];
                      acquisitions = lib.mkAfter [
                        {
                          source = "journalctl";
                          journalctl_filter = [ "_SYSTEMD_UNIT=fixture-never.service" ];
                          labels = {
                            type = "syslog";
                            fixture = marker;
                          };
                        }
                      ];
                    };
                  };
                  crowdsec-firewall-bouncer = {
                    enable = true;
                    settings.update_frequency = "1s";
                  };
                };
                systemd.services.crowdsec-setup = {
                  requires = [ "caddy.service" ];
                  after = [ "caddy.service" ];
                };
              }
              # A reproducer only: never a required failing check or a product
              # toggle. The protected fixture uses the aspect's own override.
              (lib.mkIf (upgraded && !protectConsole) {
                systemd.tmpfiles.settings."10-crowdsec".${config.services.crowdsec.settings.config.api.server.console_path}."f+".type =
                  lib.mkOverride 40 "f+";
              })
            ];
          };

        mkTest =
          protectConsole:
          pkgs.testers.runNixOSTest {
            name = "crowdsec-upgrade${lib.optionalString (!protectConsole) "-unprotected"}";
            globalTimeout = 30 * 60;
            requiredFeatures.kvm = true;
            nodes = {
              fixture = {
                imports = [
                  (generation {
                    upgraded = false;
                    inherit protectConsole;
                  })
                ];
                # No inherited engine options: each generation imports the actual
                # module/aspect it shipped, with the same fixture support below it.
                specialisation.upgraded = {
                  inheritParentConfig = false;
                  configuration = generation {
                    upgraded = true;
                    inherit protectConsole;
                  };
                };
              };
              attacker = { lib, ... }: {
                networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
                  {
                    address = "192.168.1.20";
                    prefixLength = 24;
                  }
                ];
                environment.systemPackages = [ pkgs.curl ];
              };
              control = { lib, ... }: {
                networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
                  {
                    address = "192.168.1.30";
                    prefixLength = 24;
                  }
                ];
                environment.systemPackages = [ pkgs.curl ];
              };
            };
            testScript = builtins.readFile ./crowdsec-upgrade.py;
          };
        test = mkTest true;
      in
      {
        legacyPackages = {
          crowdsec-upgrade-test = test;
          # Expected to fail the console-sharing assertion during live upgrade.
          crowdsec-upgrade-unprotected = mkTest false;
        };
        checks.crowdsec-upgrade = test // {
          meta = test.meta // {
            hestia.group = "${system}-crowdsec-runtime";
          };
        };
      }
    );
}
